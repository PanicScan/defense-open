use std::path::PathBuf;

use sysinfo::System;

#[derive(Debug, Clone)]
pub struct ProcessItem {
    pub pid: u32,
    pub name: String,
    pub exe: Option<PathBuf>,
    pub command_line: String,
    pub cpu_usage: f32,
    pub memory_kb: u64,
}

#[derive(Debug, Default)]
pub struct ProcessCollector;

impl ProcessCollector {
    pub fn collect(&self) -> Vec<ProcessItem> {
        let mut system = System::new_all();
        system.refresh_all();

        system
            .processes()
            .iter()
            .map(|(pid, process)| ProcessItem {
                pid: pid.as_u32(),
                name: process.name().to_string(),
                exe: process.exe().map(|path| path.to_path_buf()),
                command_line: process.cmd().join(" "),
                cpu_usage: process.cpu_usage(),
                memory_kb: process.memory().saturating_add(1023) / 1024,
            })
            .collect()
    }
}
