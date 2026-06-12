use defense_core::ScanReport;
use serde::{Deserialize, Serialize};

use crate::event_log::DaemonEvent;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum DaemonCommand {
    Status,
    AnalyzePath { path: String },
    ListEvents { limit: usize },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonStatus {
    pub state: String,
    pub version: String,
    pub event_log_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum DaemonResponse {
    Status(DaemonStatus),
    AnalyzePath { report: ScanReport },
    ListEvents { events: Vec<DaemonEvent> },
}
