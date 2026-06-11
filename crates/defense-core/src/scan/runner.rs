use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use chrono::Utc;
use uuid::Uuid;

use crate::analyzers::{bluetooth, miner, network, persistence, wireless};
use crate::collectors::bluetooth::BluetoothCollector;
use crate::collectors::filesystem::{FileItem, FilesystemCollector};
use crate::collectors::network::NetworkCollector;
use crate::collectors::persistence::collect_persistence_entries;
use crate::collectors::process::{ProcessCollector, ProcessItem};
use crate::collectors::wireless::WirelessCollector;
use crate::report::{Finding, ScanReport};
use crate::rules::RuleEngine;
use crate::scan::file_analysis::analyze_file_with_rules;
use crate::scan::scoring::score_evidence;
use crate::scan::target::TargetKind;
use crate::scan::{ScanPlanner, ScanRequest};

#[derive(Debug)]
pub struct ScanRunner {
    planner: ScanPlanner,
    filesystem: FilesystemCollector,
    process: ProcessCollector,
    network: NetworkCollector,
    wireless: WirelessCollector,
    bluetooth: BluetoothCollector,
    rules: RuleEngine,
    /// Atomic counter incremented after each file is analysed.
    /// The CLI reads this from a background thread to show live progress.
    pub files_analyzed: Arc<AtomicU64>,
}

impl Default for ScanRunner {
    fn default() -> Self {
        Self {
            planner: ScanPlanner,
            filesystem: FilesystemCollector::default(),
            process: ProcessCollector,
            network: NetworkCollector,
            wireless: WirelessCollector,
            bluetooth: BluetoothCollector,
            rules: RuleEngine::builtin(),
            files_analyzed: Arc::new(AtomicU64::new(0)),
        }
    }
}

impl ScanRunner {
    /// Create a runner that shares a progress counter with the caller.
    pub fn with_progress(counter: Arc<AtomicU64>) -> Self {
        Self {
            files_analyzed: counter,
            ..Self::default()
        }
    }

    pub fn run(&self, request: ScanRequest) -> Result<ScanReport> {
        let started = Utc::now();
        let deadline = effective_deadline(&request);
        let targets = self.planner.plan(&request);
        let mut scanned_files = 0u64;
        let mut findings: Vec<Finding> = Vec::new();
        let mut warnings = Vec::new();

        // ── Filesystem targets ─────────────────────────────────────────────
        for target in &targets {
            if deadline.is_some_and(|d| Instant::now() >= d) {
                warnings.push(format!(
                    "Scan time budget exhausted before scanning {}",
                    target.label
                ));
                break;
            }
            if target.kind != TargetKind::Directory {
                continue;
            }
            if let Some(path) = &target.path {
                let items = match self.filesystem.collect_directory(path, deadline) {
                    Ok(items) => items,
                    Err(error) => {
                        warnings.push(format!("Could not scan {}: {error}", path.display()));
                        continue;
                    }
                };
                scanned_files += items.len() as u64;
                let completed = analyze_file_items(
                    &items,
                    &self.rules,
                    &self.files_analyzed,
                    deadline,
                    &mut findings,
                    &mut warnings,
                    &target.label,
                );
                if !completed {
                    break;
                }
            }
        }

        // ── Persistence entries ────────────────────────────────────────────
        let persistence_entries = collect_persistence_entries();
        if deadline.is_some_and(|d| Instant::now() >= d) {
            warnings.push("Scan time budget exhausted before persistence analysis".to_string());
        } else {
            for entry in &persistence_entries {
                let evidences = persistence::analyze_persistence_entry(entry);
                if evidences.is_empty() {
                    continue;
                }
                let (score, severity, action) = score_evidence(&evidences, false);
                findings.push(Finding {
                    id: Uuid::new_v4().to_string(),
                    severity,
                    score,
                    title: "Suspicious persistence entry".to_string(),
                    explanation: "A startup or service entry contains suspicious launch behavior."
                        .to_string(),
                    item_path: None,
                    process_id: None,
                    persistence_location: Some(format!(
                        "{}:{} — {}",
                        entry.platform, entry.source, entry.name
                    )),
                    evidences,
                    recommended_action: action,
                });
            }
        }

        // ── Running processes ──────────────────────────────────────────────
        let processes = self.process.collect();
        let memory_peak_kb = current_process_memory_kb(&processes);
        if deadline.is_some_and(|d| Instant::now() >= d) {
            warnings.push("Scan time budget exhausted before process analysis".to_string());
        } else {
            for process in processes {
                let evidences = miner::analyze_process_for_miner(&process);
                if evidences.is_empty() {
                    continue;
                }
                let (score, severity, action) = score_evidence(&evidences, false);
                findings.push(Finding {
                    id: Uuid::new_v4().to_string(),
                    severity,
                    score,
                    title: "Miner-like running process".to_string(),
                    explanation:
                        "A running process has miner-like name, command line, or CPU/path behavior."
                            .to_string(),
                    item_path: process.exe.map(|path| path.display().to_string()),
                    process_id: Some(process.pid),
                    persistence_location: None,
                    evidences,
                    recommended_action: action,
                });
            }
        }

        // ── Network Sockets ────────────────────────────────────────────────
        let sockets = self.network.collect();
        if deadline.is_some_and(|d| Instant::now() >= d) {
            warnings.push("Scan time budget exhausted before network analysis".to_string());
        } else {
            for socket in sockets {
                let evidences = network::analyze_network_connection(&socket);
                if evidences.is_empty() {
                    continue;
                }
                let (score, severity, action) = score_evidence(&evidences, false);
                findings.push(Finding {
                    id: Uuid::new_v4().to_string(),
                    severity,
                    score,
                    title: "Suspicious network activity".to_string(),
                    explanation: "A process is using a suspicious network port or exposing an administrative listener.".to_string(),
                    item_path: None, // Could be enhanced by joining with `processes` list
                    process_id: socket.pid,
                    persistence_location: None,
                    evidences,
                    recommended_action: action,
                });
            }
        }

        // ── Wireless (Wi-Fi) ───────────────────────────────────────────────
        let wifi_items = self.wireless.collect();
        if deadline.is_some_and(|d| Instant::now() >= d) {
            warnings.push("Scan time budget exhausted before wireless analysis".to_string());
        } else {
            let evidences = wireless::analyze_wireless_networks(&wifi_items);
            if !evidences.is_empty() {
                let (score, severity, action) = score_evidence(&evidences, false);
                findings.push(Finding {
                    id: Uuid::new_v4().to_string(),
                    severity,
                    score,
                    title: "Rogue Wi-Fi Access Point (Evil Twin)".to_string(),
                    explanation:
                        "Detected potential Evil Twin or Karma attack in nearby wireless networks."
                            .to_string(),
                    item_path: None,
                    process_id: None,
                    persistence_location: None,
                    evidences,
                    recommended_action: action,
                });
            }
        }

        // ── Bluetooth (BLE) ────────────────────────────────────────────────
        if let Ok(rt) = tokio::runtime::Runtime::new() {
            let bt_items = rt.block_on(self.bluetooth.collect());
            if deadline.is_some_and(|d| Instant::now() >= d) {
                warnings.push("Scan time budget exhausted before bluetooth analysis".to_string());
            } else {
                let evidences = bluetooth::analyze_bluetooth_devices(&bt_items);
                if !evidences.is_empty() {
                    let (score, severity, action) = score_evidence(&evidences, false);
                    findings.push(Finding {
                        id: Uuid::new_v4().to_string(),
                        severity,
                        score,
                        title: "Malicious Bluetooth Activity".to_string(),
                        explanation:
                            "Detected offensive BLE hardware or beacon flood attack nearby."
                                .to_string(),
                        item_path: None,
                        process_id: None,
                        persistence_location: None,
                        evidences,
                        recommended_action: action,
                    });
                }
            }
        }

        findings.sort_by_key(|finding| std::cmp::Reverse(finding.score));
        let finished = Utc::now();

        Ok(ScanReport {
            schema_version: "1".to_string(),
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            mode: request.mode,
            started_at: started.to_rfc3339(),
            finished_at: finished.to_rfc3339(),
            duration_ms: (finished - started).num_milliseconds().max(0) as u64,
            memory_peak_kb,
            scanned_files,
            scanned_persistence_entries: persistence_entries.len() as u64,
            findings,
            warnings,
        })
    }
}

/// Returns `false` if the deadline was hit mid-analysis (scan must stop).
fn analyze_file_items(
    items: &[FileItem],
    rules: &RuleEngine,
    counter: &Arc<AtomicU64>,
    deadline: Option<Instant>,
    findings: &mut Vec<Finding>,
    warnings: &mut Vec<String>,
    target_label: &str,
) -> bool {
    for item in items {
        if deadline.is_some_and(|d| Instant::now() >= d) {
            warnings.push(format!(
                "Scan time budget exhausted while analyzing {target_label}"
            ));
            return false;
        }
        if let Some(finding) = analyze_file_with_rules(item, rules) {
            findings.push(finding);
        }
        counter.fetch_add(1, Ordering::Relaxed);
    }
    true
}

/// Return a deadline if the request or env var specifies a limit; else `None`.
///
/// Priority:
///   1. `request.max_minutes > 0` (set via `--max-minutes` CLI flag)
///   2. `DEFENSE_SCAN_MAX_MINUTES` env var (used by CI smoke tests)
///   3. No deadline (default for normal interactive use)
fn effective_deadline(request: &ScanRequest) -> Option<Instant> {
    if request.max_minutes > 0 {
        return Some(Instant::now() + Duration::from_secs(request.max_minutes * 60));
    }
    if let Ok(val) = std::env::var("DEFENSE_SCAN_MAX_MINUTES") {
        if let Ok(mins) = val.parse::<u64>() {
            if mins > 0 {
                return Some(Instant::now() + Duration::from_secs(mins * 60));
            }
        }
    }
    None
}

fn current_process_memory_kb(processes: &[ProcessItem]) -> Option<u64> {
    let current_pid = std::process::id();
    processes
        .iter()
        .find(|process| process.pid == current_pid)
        .map(|process| process.memory_kb)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collectors::filesystem::FileItem;
    use std::fs;

    #[test]
    fn file_analysis_increments_counter_and_finds_threat() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("run.ps1");
        fs::write(&script, "powershell -EncodedCommand SQBFAFgA").unwrap();
        let items = vec![FileItem {
            path: script,
            size: 34,
            modified: None,
        }];
        let counter = Arc::new(AtomicU64::new(0));
        let mut findings = Vec::new();

        let mut warnings = Vec::new();
        analyze_file_items(
            &items,
            &RuleEngine::builtin(),
            &counter,
            None,
            &mut findings,
            &mut warnings,
            "test target",
        );

        assert_eq!(
            counter.load(Ordering::Relaxed),
            1,
            "counter must equal item count"
        );
        assert!(
            !findings.is_empty(),
            "encoded command must produce a finding"
        );
    }
}
