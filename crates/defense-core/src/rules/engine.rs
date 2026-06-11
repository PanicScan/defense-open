use std::path::Path;

use crate::report::{Evidence, EvidenceKind};
use crate::rules::schema::PanicRule;

const BUILTIN_RULES_JSON: &str = include_str!("../../../../rules/builtin/miner.defense.json");

#[derive(Debug, Clone, Default)]
pub struct RuleEngine {
    rules: Vec<PanicRule>,
}

impl RuleEngine {
    pub fn new(rules: Vec<PanicRule>) -> Self {
        Self { rules }
    }

    pub fn builtin() -> Self {
        Self::from_json_str(BUILTIN_RULES_JSON).expect("built-in defense rules must parse")
    }

    pub fn from_json_str(text: &str) -> Result<Self, serde_json::Error> {
        Ok(Self::new(serde_json::from_str(text)?))
    }

    pub fn scan_bytes(&self, path: &Path, bytes: &[u8]) -> Vec<Evidence> {
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let lower = bytes
            .iter()
            .map(|byte| byte.to_ascii_lowercase())
            .collect::<Vec<_>>();

        self.rules
            .iter()
            .filter(|rule| {
                rule.extensions.is_empty()
                    || rule
                        .extensions
                        .iter()
                        .any(|item| item.eq_ignore_ascii_case(&extension))
            })
            .filter(|rule| {
                rule.ascii_contains
                    .iter()
                    .any(|needle| contains(&lower, needle.to_ascii_lowercase().as_bytes()))
            })
            .map(|rule| Evidence {
                kind: parse_kind(&rule.evidence_kind),
                code: format!("rule.{}", rule.id),
                title: rule.title.clone(),
                detail: format!("Matched built-in rule {}", rule.id),
                weight: rule.weight,
            })
            .collect()
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

fn parse_kind(value: &str) -> EvidenceKind {
    match value {
        "miner" => EvidenceKind::Miner,
        "script" => EvidenceKind::Script,
        "persistence" => EvidenceKind::Persistence,
        "shortcut" => EvidenceKind::Shortcut,
        "browser" => EvidenceKind::Browser,
        "network" => EvidenceKind::Network,
        "reputation" => EvidenceKind::Reputation,
        "execution" => EvidenceKind::Execution,
        _ => EvidenceKind::File,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_ascii_rule_by_extension() {
        let engine = RuleEngine::new(vec![PanicRule {
            id: "miner-string".to_string(),
            title: "Miner string".to_string(),
            evidence_kind: "miner".to_string(),
            weight: 35,
            ascii_contains: vec!["stratum+tcp".to_string()],
            extensions: vec!["exe".to_string()],
        }]);
        let evidences = engine.scan_bytes(Path::new("a.exe"), b"STRATUM+TCP://pool");
        assert_eq!(evidences.len(), 1);
        assert_eq!(evidences[0].kind, EvidenceKind::Miner);
    }

    #[test]
    fn parses_builtin_rules() {
        let engine = RuleEngine::builtin();
        let evidences = engine.scan_bytes(Path::new("miner.ps1"), b"stratum+tcp://pool");
        assert!(evidences
            .iter()
            .any(|evidence| evidence.code == "rule.miner-pool-string"));
    }
}
