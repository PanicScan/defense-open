use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::Utc;
use defense_core::collectors::filesystem::FileItem;
use defense_core::scan::file_analysis::analyze_file;
use defense_core::{ScanMode, ScanReport, ScanRequest, ScanRunner};

use crate::event_log::{DaemonEvent, EventLog};
use crate::ipc_types::{DaemonCommand, DaemonResponse, DaemonStatus};

#[derive(Debug)]
pub struct DaemonService {
    event_log: EventLog,
    scanner: ScanRunner,
}

impl DaemonService {
    pub fn new(event_log_path: impl Into<PathBuf>) -> Self {
        Self {
            event_log: EventLog::new(event_log_path),
            scanner: ScanRunner::default(),
        }
    }

    pub fn status(&self) -> DaemonStatus {
        DaemonStatus {
            state: "ready".to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            event_log_path: self.event_log.path().display().to_string(),
        }
    }

    pub fn handle(&self, command: DaemonCommand) -> Result<DaemonResponse> {
        match command {
            DaemonCommand::Status => {
                self.record("status", "daemon status requested")?;
                Ok(DaemonResponse::Status(self.status()))
            }
            DaemonCommand::AnalyzePath { path } => {
                self.record("analyze_path", &path)?;
                let report = self.analyze_path(&path)?;
                Ok(DaemonResponse::AnalyzePath { report })
            }
            DaemonCommand::ListEvents { limit } => {
                self.record("list_events", &format!("limit={limit}"))?;
                let events = self.event_log.list_recent(limit)?;
                Ok(DaemonResponse::ListEvents { events })
            }
        }
    }

    fn analyze_path(&self, path: &str) -> Result<ScanReport> {
        let path = PathBuf::from(path);
        if path.is_file() {
            return analyze_single_file(&path);
        }

        let request = ScanRequest::new(ScanMode::Usb)
            .with_root(path.display().to_string())
            .with_max_minutes(5);
        self.scanner.run(request)
    }

    fn record(&self, kind: &str, detail: &str) -> Result<()> {
        self.event_log.append(&DaemonEvent {
            kind: kind.to_string(),
            message: detail.to_string(),
            created_at: Utc::now().to_rfc3339(),
        })
    }
}

fn analyze_single_file(path: &Path) -> Result<ScanReport> {
    let started = Utc::now();
    let metadata =
        fs::metadata(path).with_context(|| format!("read metadata {}", path.display()))?;
    let item = FileItem {
        path: path.to_path_buf(),
        size: metadata.len(),
        modified: metadata.modified().ok(),
    };
    let findings = analyze_file(&item).into_iter().collect();
    let finished = Utc::now();

    Ok(ScanReport {
        schema_version: "1".to_string(),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        mode: ScanMode::Usb,
        started_at: started.to_rfc3339(),
        finished_at: finished.to_rfc3339(),
        duration_ms: (finished - started).num_milliseconds().max(0) as u64,
        memory_peak_kb: None,
        scanned_files: 1,
        scanned_persistence_entries: 0,
        findings,
        warnings: Vec::new(),
    })
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn status_reports_ready_state_and_event_log_path() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("events.jsonl");
        let service = DaemonService::new(&path);

        let status = service.status();

        assert_eq!(status.state, "ready");
        assert_eq!(status.version, env!("CARGO_PKG_VERSION"));
        assert_eq!(status.event_log_path, path.display().to_string());
    }

    #[test]
    fn handle_status_records_event() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("events.jsonl");
        let service = DaemonService::new(&path);

        let response = service.handle(DaemonCommand::Status).expect("status");
        let events = EventLog::new(path).list_recent(10).expect("events");

        assert!(matches!(response, DaemonResponse::Status(_)));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, "status");
        assert_eq!(events[0].message, "daemon status requested");
    }

    #[test]
    fn analyze_path_handles_single_file() {
        let dir = tempdir().expect("tempdir");
        let event_log_path = dir.path().join("events.jsonl");
        let sample_path = dir.path().join("run.ps1");
        std::fs::write(&sample_path, "powershell -EncodedCommand SQBFAFgA").expect("write sample");
        let service = DaemonService::new(event_log_path);

        let response = service
            .handle(DaemonCommand::AnalyzePath {
                path: sample_path.display().to_string(),
            })
            .expect("analyze path");

        let DaemonResponse::AnalyzePath { report } = response else {
            panic!("expected analyze path response");
        };
        assert_eq!(report.scanned_files, 1);
        assert!(!report.findings.is_empty());
        assert_eq!(report.scanned_persistence_entries, 0);
    }
}
