use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PanicRule {
    pub id: String,
    pub title: String,
    pub evidence_kind: String,
    pub weight: u8,
    pub ascii_contains: Vec<String>,
    pub extensions: Vec<String>,
}
