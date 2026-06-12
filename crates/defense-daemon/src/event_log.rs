use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonEvent {
    pub kind: String,
    pub message: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventLog {
    path: PathBuf,
}

impl EventLog {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn append(&self, event: &DaemonEvent) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("create event log directory {}", parent.display()))?;
        }

        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .with_context(|| format!("open event log {}", self.path.display()))?;
        serde_json::to_writer(&mut file, event).context("serialize daemon event")?;
        writeln!(file).context("write daemon event newline")?;
        Ok(())
    }

    pub fn list_recent(&self, limit: usize) -> Result<Vec<DaemonEvent>> {
        if limit == 0 || !self.path.exists() {
            return Ok(Vec::new());
        }

        let file = File::open(&self.path)
            .with_context(|| format!("open event log {}", self.path.display()))?;
        let reader = BufReader::new(file);
        let mut events = Vec::new();

        for line in reader.lines() {
            let line = line.with_context(|| format!("read event log {}", self.path.display()))?;
            if line.trim().is_empty() {
                continue;
            }
            let event = serde_json::from_str(&line).context("parse daemon event line")?;
            events.push(event);
        }

        let keep_from = events.len().saturating_sub(limit);
        Ok(events.split_off(keep_from))
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn event_log_appends_and_lists_recent_events() {
        let dir = tempdir().expect("tempdir");
        let log = EventLog::new(dir.path().join("events.jsonl"));

        log.append(&DaemonEvent {
            kind: "status".to_string(),
            message: "started".to_string(),
            created_at: "2026-06-11T00:00:00Z".to_string(),
        })
        .expect("append first event");
        log.append(&DaemonEvent {
            kind: "scan".to_string(),
            message: "analyzed path".to_string(),
            created_at: "2026-06-11T00:00:01Z".to_string(),
        })
        .expect("append second event");

        let events = log.list_recent(1).expect("read events");

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, "scan");
        assert_eq!(events[0].message, "analyzed path");
    }

    #[test]
    fn missing_log_reads_as_empty() {
        let dir = tempdir().expect("tempdir");
        let log = EventLog::new(dir.path().join("missing.jsonl"));

        assert_eq!(log.list_recent(10).expect("read missing log"), Vec::new());
    }
}
