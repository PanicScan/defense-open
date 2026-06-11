use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetKind {
    File,
    Directory,
    PersistenceEntry,
    Process,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanTarget {
    pub kind: TargetKind,
    pub path: Option<PathBuf>,
    pub label: String,
}

impl ScanTarget {
    pub fn directory(path: impl Into<PathBuf>, label: impl Into<String>) -> Self {
        Self {
            kind: TargetKind::Directory,
            path: Some(path.into()),
            label: label.into(),
        }
    }
}
