use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime};

use anyhow::Result;
use walkdir::WalkDir;

#[derive(Debug, Clone)]
pub struct FileItem {
    pub path: PathBuf,
    pub size: u64,
    pub modified: Option<SystemTime>,
}

#[derive(Debug, Clone)]
pub struct FilesystemCollector {
    pub max_depth: usize,
}

impl Default for FilesystemCollector {
    fn default() -> Self {
        Self { max_depth: 12 }
    }
}

impl FilesystemCollector {
    /// Collect interesting files under `root`.
    ///
    /// If `deadline` is `Some` the walk stops as soon as the deadline is
    /// reached, returning whatever has been collected so far.  Pass `None`
    /// for no limit.
    pub fn collect_directory(
        &self,
        root: &Path,
        deadline: Option<Instant>,
    ) -> Result<Vec<FileItem>> {
        let mut items = Vec::new();
        if !root.exists() {
            return Ok(items);
        }

        for entry in WalkDir::new(root)
            .max_depth(self.max_depth)
            .follow_links(false)
            .into_iter()
            .filter_map(|entry| entry.ok())
        {
            // Honour deadline during the walk itself, not just during analysis.
            if deadline.is_some_and(|d| Instant::now() >= d) {
                break;
            }

            if !entry.file_type().is_file() {
                continue;
            }

            let metadata = match entry.metadata() {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };

            if !is_interesting_path(entry.path()) {
                continue;
            }

            // Skip very large files (>8MB) — not useful for static analysis
            if metadata.len() > 8 * 1024 * 1024 {
                continue;
            }

            items.push(FileItem {
                path: entry.path().to_path_buf(),
                size: metadata.len(),
                modified: metadata.modified().ok(),
            });
        }

        Ok(items)
    }
}

pub fn is_interesting_extension(path: &Path) -> bool {
    let Some(extension) = path.extension().and_then(|value| value.to_str()) else {
        return false;
    };

    matches!(
        extension.to_ascii_lowercase().as_str(),
        "exe"
            | "dll"
            | "scr"
            | "com"
            | "bat"
            | "cmd"
            | "ps1"
            | "vbs"
            | "js"
            | "jse"
            | "wsf"
            | "hta"
            | "msi"
            | "lnk"
            | "inf"
            | "sh"
            | "command"
            | "desktop"
            | "service"
            | "plist"
            | "dylib"
            | "so"
            | "bin"
    )
}

fn is_interesting_path(path: &Path) -> bool {
    is_interesting_extension(path) || is_browser_manifest(path) || is_extensionless_candidate(path)
}

fn is_browser_manifest(path: &Path) -> bool {
    path.file_name()
        .and_then(|value| value.to_str())
        .map(|value| value.eq_ignore_ascii_case("manifest.json"))
        .unwrap_or(false)
}

fn is_extensionless_candidate(path: &Path) -> bool {
    path.extension().is_none()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn filters_interesting_extensions() {
        assert!(is_interesting_extension(Path::new("setup.exe")));
        assert!(is_interesting_extension(Path::new("agent.plist")));
        assert!(is_interesting_extension(Path::new("autostart.desktop")));
        assert!(!is_interesting_extension(Path::new("photo.jpg")));
    }

    #[test]
    fn collects_files_without_following_links() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a.exe"), b"test").unwrap();
        let items = FilesystemCollector::default()
            .collect_directory(dir.path(), None)
            .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].size, 4);
    }

    #[test]
    fn wires_browser_manifest_collection() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join("manifest.json"),
            br#"{"permissions":["<all_urls>"]}"#,
        )
        .unwrap();
        fs::write(dir.path().join("package.json"), br#"{"private":true}"#).unwrap();

        let items = FilesystemCollector::default()
            .collect_directory(dir.path(), None)
            .unwrap();

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].path.file_name().unwrap(), "manifest.json");
    }
}
