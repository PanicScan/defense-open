use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::report::{Finding, ScanReport};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FeatureExport {
    pub schema_version: String,
    pub source_report_schema_version: String,
    pub app_version: String,
    pub mode: String,
    pub vector_count: usize,
    pub vectors: Vec<FindingFeatureVector>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FindingFeatureVector {
    pub finding_ref: String,
    pub severity: String,
    pub score: u8,
    pub score_band: String,
    pub recommended_action: String,
    pub has_item_path: bool,
    pub has_process_id: bool,
    pub has_persistence_location: bool,
    pub path_class: String,
    pub path_extension: Option<String>,
    pub evidence_count: usize,
    pub evidence_weight_sum: u16,
    pub evidence_kinds: Vec<String>,
    pub evidence_codes: Vec<String>,
}

pub fn export_feature_vectors(report: &ScanReport) -> FeatureExport {
    let vectors = report
        .findings
        .iter()
        .enumerate()
        .map(|(index, finding)| feature_vector_from_finding(index, finding))
        .collect::<Vec<_>>();

    FeatureExport {
        schema_version: "defense.features.v1".to_string(),
        source_report_schema_version: report.schema_version.clone(),
        app_version: report.app_version.clone(),
        mode: format!("{:?}", report.mode),
        vector_count: vectors.len(),
        vectors,
    }
}

fn feature_vector_from_finding(index: usize, finding: &Finding) -> FindingFeatureVector {
    let mut evidence_kinds = finding
        .evidences
        .iter()
        .map(|evidence| format!("{:?}", evidence.kind))
        .collect::<Vec<_>>();
    evidence_kinds.sort();
    evidence_kinds.dedup();

    FindingFeatureVector {
        finding_ref: format!("finding-{number:06}", number = index + 1),
        severity: format!("{:?}", finding.severity),
        score: finding.score,
        score_band: score_band(finding.score).to_string(),
        recommended_action: format!("{:?}", finding.recommended_action),
        has_item_path: finding.item_path.is_some(),
        has_process_id: finding.process_id.is_some(),
        has_persistence_location: finding.persistence_location.is_some(),
        path_class: path_class(finding.item_path.as_deref()).to_string(),
        path_extension: finding.item_path.as_deref().and_then(path_extension),
        evidence_count: finding.evidences.len(),
        evidence_weight_sum: finding
            .evidences
            .iter()
            .map(|evidence| u16::from(evidence.weight))
            .sum(),
        evidence_kinds,
        evidence_codes: finding
            .evidences
            .iter()
            .map(|evidence| evidence.code.clone())
            .collect(),
    }
}

fn score_band(score: u8) -> &'static str {
    match score {
        0..=19 => "clean_looking",
        20..=39 => "noteworthy",
        40..=59 => "suspicious",
        60..=79 => "high_risk",
        _ => "likely_malicious",
    }
}

fn path_extension(path: &str) -> Option<String> {
    Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .filter(|extension| !extension.is_empty())
}

fn path_class(path: Option<&str>) -> &'static str {
    let Some(path) = path else {
        return "none";
    };
    let normalized = path.replace('\\', "/").to_ascii_lowercase();

    if normalized.contains("/downloads/") {
        "user_downloads"
    } else if normalized.contains("/desktop/") {
        "user_desktop"
    } else if normalized.contains("/appdata/local/temp/")
        || normalized.contains("/tmp/")
        || normalized.starts_with("/tmp/")
    {
        "temp"
    } else if normalized.starts_with("/volumes/")
        || normalized.starts_with("/media/")
        || normalized.starts_with("/mnt/")
    {
        "removable_or_mounted"
    } else if normalized.starts_with("/system/")
        || normalized.starts_with("/usr/bin/")
        || normalized.starts_with("/usr/libexec/")
        || normalized.starts_with("/bin/")
        || normalized.starts_with("/sbin/")
        || normalized.contains("/windows/system32/")
    {
        "system"
    } else {
        "other"
    }
}
