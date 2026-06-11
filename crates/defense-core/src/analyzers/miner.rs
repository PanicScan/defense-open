use crate::collectors::process::ProcessItem;
use crate::report::{Evidence, EvidenceKind};

const MINER_NAMES: &[&str] = &[
    "xmrig",
    "xmr-stak",
    "nanominer",
    "nbminer",
    "lolminer",
    "teamredminer",
];

const MINER_TERMS: &[&str] = &[
    "stratum+tcp",
    "stratum+ssl",
    "monero",
    "randomx",
    "nanopool",
    "supportxmr",
    "minexmr",
];

pub fn analyze_process_for_miner(process: &ProcessItem) -> Vec<Evidence> {
    let mut evidences = Vec::new();
    let name = process.name.to_ascii_lowercase();
    let command_line = process.command_line.to_ascii_lowercase();
    let executable_name = process
        .exe
        .as_ref()
        .and_then(|path| path.file_name())
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase());

    if MINER_NAMES.iter().any(|term| name.contains(term))
        || executable_name
            .as_deref()
            .is_some_and(|value| MINER_NAMES.iter().any(|term| value.contains(term)))
    {
        let detail = match &process.exe {
            Some(path) => format!(
                "Process name is {} and executable path is {}",
                process.name,
                path.display()
            ),
            None => format!("Process name is {}", process.name),
        };
        evidences.push(Evidence {
            kind: EvidenceKind::Miner,
            code: "miner.process_name".to_string(),
            title: "Known miner-like process name".to_string(),
            detail,
            weight: 35,
        });
    }

    if MINER_TERMS.iter().any(|term| command_line.contains(term)) {
        evidences.push(Evidence {
            kind: EvidenceKind::Miner,
            code: "miner.command_line".to_string(),
            title: "Miner-like command line".to_string(),
            detail: "Command line contains mining pool or mining algorithm term".to_string(),
            weight: 35,
        });
    }

    if process.cpu_usage >= 40.0
        && process.exe.as_ref().is_some_and(|path| {
            let text = path.display().to_string().to_ascii_lowercase();
            text.contains("/tmp")
                || text.contains("/downloads")
                || text.contains("\\appdata\\")
                || text.contains("\\temp\\")
                || text.contains("\\downloads\\")
        })
    {
        evidences.push(Evidence {
            kind: EvidenceKind::Execution,
            code: "process.high_cpu_user_path".to_string(),
            title: "High CPU process from user-writable path".to_string(),
            detail: format!("CPU usage sampled at {:.1}%", process.cpu_usage),
            weight: 20,
        });
    }

    evidences
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn detects_xmrig_name() {
        let item = ProcessItem {
            pid: 10,
            name: "xmrig.exe".to_string(),
            exe: None,
            command_line: String::new(),
            cpu_usage: 0.0,
            memory_kb: 0,
        };
        let evidences = analyze_process_for_miner(&item);
        assert_eq!(evidences[0].code, "miner.process_name");
    }

    #[test]
    fn detects_xmrig_executable_path_when_process_name_is_generic() {
        let item = ProcessItem {
            pid: 10,
            name: "sleep.exe".to_string(),
            exe: Some(PathBuf::from(r"C:\Temp\xmrig.exe")),
            command_line: String::new(),
            cpu_usage: 0.0,
            memory_kb: 0,
        };
        let evidences = analyze_process_for_miner(&item);
        assert_eq!(evidences[0].code, "miner.process_name");
    }
}
