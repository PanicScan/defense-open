use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use chrono::Utc;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::quarantine::metadata::QuarantineMetadata;

#[derive(Debug, Clone)]
pub struct QuarantineManager {
    root: PathBuf,
}

impl QuarantineManager {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn quarantine_file(
        &self,
        original_path: &Path,
        finding_id: &str,
    ) -> Result<QuarantineMetadata> {
        if !original_path.is_file() {
            return Err(anyhow!("quarantine target is not a file"));
        }

        fs::create_dir_all(&self.root)?;
        let bytes = fs::read(original_path)?;
        let sha256 = format!("{:x}", Sha256::digest(&bytes));
        let id = Uuid::new_v4().to_string();
        let quarantine_path = self.root.join(format!("{id}.quar"));
        fs::write(&quarantine_path, &bytes)?;
        fs::remove_file(original_path)?;

        let metadata = QuarantineMetadata {
            id: id.clone(),
            original_path: original_path.display().to_string(),
            quarantine_path: quarantine_path.display().to_string(),
            sha256,
            created_at: Utc::now().to_rfc3339(),
            finding_id: finding_id.to_string(),
        };

        fs::write(
            self.root.join(format!("{id}.json")),
            serde_json::to_vec_pretty(&metadata)?,
        )?;
        Ok(metadata)
    }

    pub fn restore_file(&self, metadata: &QuarantineMetadata) -> Result<()> {
        let quarantine_path = PathBuf::from(&metadata.quarantine_path);
        let original_path = PathBuf::from(&metadata.original_path);
        if let Some(parent) = original_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&quarantine_path, &original_path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quarantine_and_restore_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let quarantine = dir.path().join("q");
        let original = dir.path().join("bad.exe");
        fs::write(&original, b"sample").unwrap();

        let manager = QuarantineManager::new(&quarantine);
        let metadata = manager.quarantine_file(&original, "finding-1").unwrap();
        assert!(!original.exists());

        manager.restore_file(&metadata).unwrap();
        assert_eq!(fs::read(&original).unwrap(), b"sample");
    }
}
