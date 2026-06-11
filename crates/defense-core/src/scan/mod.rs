pub mod file_analysis;
mod planner;
mod runner;
pub mod scoring;
pub mod target;

pub use planner::ScanPlanner;
pub use runner::ScanRunner;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub enum ScanMode {
    Quick,
    Usb,
    Full,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanRequest {
    pub mode: ScanMode,
    pub roots: Vec<String>,
    pub max_minutes: u64,
}

impl ScanRequest {
    pub fn new(mode: ScanMode) -> Self {
        Self {
            mode,
            roots: Vec::new(),
            max_minutes: 0, // 0 = no limit; set > 0 or DEFENSE_SCAN_MAX_MINUTES to cap
        }
    }

    pub fn with_root(mut self, root: String) -> Self {
        self.roots.push(root);
        self
    }

    pub fn with_max_minutes(mut self, max_minutes: u64) -> Self {
        self.max_minutes = max_minutes;
        self
    }
}
