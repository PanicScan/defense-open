use anyhow::Result;

use crate::report::redaction::redact_report;
use crate::report::ScanReport;

pub fn to_pretty_json(report: &ScanReport) -> Result<String> {
    Ok(serde_json::to_string_pretty(&redact_report(report))?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::report::{
        Evidence, EvidenceKind, Finding, FindingSeverity, RecommendedAction, ScanReport,
    };
    use crate::scan::ScanMode;

    #[test]
    fn json_report_redacts_user_paths_and_secrets() {
        let report = ScanReport {
            schema_version: "1".to_string(),
            app_version: "0.1.0".to_string(),
            mode: ScanMode::Quick,
            started_at: "now".to_string(),
            finished_at: "now".to_string(),
            duration_ms: 1,
            memory_peak_kb: Some(1),
            scanned_files: 1,
            scanned_persistence_entries: 1,
            findings: vec![Finding {
                id: "finding-1".to_string(),
                severity: FindingSeverity::High,
                score: 75,
                title: "Suspicious file".to_string(),
                explanation: "Found under /Users/Ali/Downloads".to_string(),
                item_path: Some("/Users/Ali/Downloads/run.ps1".to_string()),
                process_id: None,
                persistence_location: Some(
                    "windows:HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run".to_string(),
                ),
                evidences: vec![Evidence {
                    kind: EvidenceKind::Script,
                    code: "script.download_execute".to_string(),
                    title: "Downloader".to_string(),
                    detail: "powershell token=abc C:\\Users\\Veli\\AppData\\Roaming\\run.ps1"
                        .to_string(),
                    weight: 25,
                }],
                recommended_action: RecommendedAction::Review,
            }],
            warnings: vec!["Could not scan /Users/Ali/Secret".to_string()],
        };

        let json = to_pretty_json(&report).expect("serialize report");

        assert!(!json.contains("/Users/Ali"));
        assert!(!json.contains("C:\\\\Users\\\\Veli"));
        assert!(!json.contains("token=abc"));
        assert!(json.contains("/Users/<user>/Downloads/run.ps1"));
        assert!(json.contains("C:\\\\Users\\\\<user>\\\\AppData"));
        assert!(json.contains("<redacted>"));
    }
}
