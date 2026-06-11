use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrustStatus {
    Trusted,
    Untrusted,
    Unsigned,
    Unknown,
}

pub fn inspect_platform_trust(_path: &Path) -> TrustStatus {
    TrustStatus::Unknown
}
