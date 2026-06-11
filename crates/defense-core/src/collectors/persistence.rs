#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistenceEntry {
    pub platform: String,
    pub source: String,
    pub name: String,
    pub command: String,
}

pub fn collect_persistence_entries() -> Vec<PersistenceEntry> {
    let mut entries = Vec::new();
    entries.extend(crate::collectors::windows_persistence::collect_windows_persistence());
    entries.extend(crate::collectors::macos_persistence::collect_macos_persistence());
    entries.extend(crate::collectors::linux_persistence::collect_linux_persistence());
    entries
}
