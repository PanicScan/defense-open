pub mod features;
pub mod html;
pub mod json;
pub mod redaction;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum FindingSeverity {
    Info,
    Low,
    Medium,
    High,
    Critical,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum EvidenceKind {
    Persistence,
    Execution,
    File,
    Script,
    Shortcut,
    Browser,
    Network,
    Miner,
    Reputation,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum RecommendedAction {
    Ignore,
    Review,
    Quarantine,
    OfflineSecurityScan,
    ManualExpertReview,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Evidence {
    pub kind: EvidenceKind,
    pub code: String,
    pub title: String,
    pub detail: String,
    pub weight: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Finding {
    pub id: String,
    pub severity: FindingSeverity,
    pub score: u8,
    pub title: String,
    pub explanation: String,
    pub item_path: Option<String>,
    pub process_id: Option<u32>,
    pub persistence_location: Option<String>,
    pub evidences: Vec<Evidence>,
    pub recommended_action: RecommendedAction,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ScanReport {
    pub schema_version: String,
    pub app_version: String,
    pub mode: crate::scan::ScanMode,
    pub started_at: String,
    pub finished_at: String,
    pub duration_ms: u64,
    pub memory_peak_kb: Option<u64>,
    pub scanned_files: u64,
    pub scanned_persistence_entries: u64,
    pub findings: Vec<Finding>,
    pub warnings: Vec<String>,
}

#[cfg(test)]
mod feature_tests {
    use super::*;
    use crate::scan::ScanMode;

    #[test]
    fn feature_export_normalizes_findings_without_raw_user_paths() {
        let report = ScanReport {
            schema_version: "1".to_string(),
            app_version: "0.1.0".to_string(),
            mode: ScanMode::Quick,
            started_at: "2026-06-07T00:00:00Z".to_string(),
            finished_at: "2026-06-07T00:00:01Z".to_string(),
            duration_ms: 1000,
            memory_peak_kb: Some(1024),
            scanned_files: 1,
            scanned_persistence_entries: 0,
            findings: vec![Finding {
                id: "raw-/Users/defenseSecretUser/Downloads/run.ps1".to_string(),
                severity: FindingSeverity::High,
                score: 77,
                title: "Suspicious script".to_string(),
                explanation: "Encoded PowerShell".to_string(),
                item_path: Some("/Users/defenseSecretUser/Downloads/run.ps1".to_string()),
                process_id: None,
                persistence_location: None,
                evidences: vec![Evidence {
                    kind: EvidenceKind::Script,
                    code: "script.encoded_powershell".to_string(),
                    title: "Encoded command".to_string(),
                    detail: "powershell -EncodedCommand ...".to_string(),
                    weight: 80,
                }],
                recommended_action: RecommendedAction::Quarantine,
            }],
            warnings: Vec::new(),
        };

        let export = features::export_feature_vectors(&report);
        let json = serde_json::to_string(&export).expect("serialize feature export");

        assert_eq!(export.schema_version, "defense.features.v1");
        assert_eq!(export.source_report_schema_version, "1");
        assert_eq!(export.vectors.len(), 1);
        assert_eq!(export.vectors[0].finding_ref, "finding-000001");
        assert_eq!(export.vectors[0].path_class, "user_downloads");
        assert_eq!(export.vectors[0].path_extension.as_deref(), Some("ps1"));
        assert_eq!(
            export.vectors[0].evidence_codes,
            vec!["script.encoded_powershell"]
        );
        assert_eq!(export.vectors[0].evidence_weight_sum, 80);
        assert!(!json.contains("defenseSecretUser"));
        assert!(!json.contains("/Users/"));
        assert!(!json.contains("raw-"));
    }
}
