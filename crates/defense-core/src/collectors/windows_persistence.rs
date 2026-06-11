use crate::collectors::persistence::PersistenceEntry;

#[cfg(windows)]
pub fn collect_windows_persistence() -> Vec<PersistenceEntry> {
    let mut entries = collect_run_keys();
    entries.extend(collect_scheduled_tasks());
    entries
}

#[cfg(not(windows))]
pub fn collect_windows_persistence() -> Vec<PersistenceEntry> {
    Vec::new()
}

#[cfg(windows)]
fn collect_run_keys() -> Vec<PersistenceEntry> {
    use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
    use winreg::RegKey;

    let locations = [
        (
            HKEY_CURRENT_USER,
            "HKCU",
            "Software\\Microsoft\\Windows\\CurrentVersion\\Run",
        ),
        (
            HKEY_CURRENT_USER,
            "HKCU",
            "Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",
        ),
        (
            HKEY_LOCAL_MACHINE,
            "HKLM",
            "Software\\Microsoft\\Windows\\CurrentVersion\\Run",
        ),
        (
            HKEY_LOCAL_MACHINE,
            "HKLM",
            "Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce",
        ),
    ];

    let mut entries = Vec::new();
    for (hive, hive_name, path) in locations {
        let root = RegKey::predef(hive);
        let Ok(key) = root.open_subkey(path) else {
            continue;
        };

        for value in key.enum_values().filter_map(|value| value.ok()) {
            let name = value.0;
            let command = decode_registry_string_lossy(&value.1.bytes);
            entries.push(PersistenceEntry {
                platform: "windows".to_string(),
                source: format!("{hive_name}\\{path}"),
                name,
                command,
            });
        }
    }

    entries
}

#[cfg(windows)]
fn collect_scheduled_tasks() -> Vec<PersistenceEntry> {
    let Ok(output) = std::process::Command::new("schtasks")
        .args(["/query", "/fo", "csv", "/v"])
        .output()
    else {
        return Vec::new();
    };

    if !output.status.success() {
        return Vec::new();
    }

    parse_schtasks_csv_lossy(&String::from_utf8_lossy(&output.stdout))
}

pub fn parse_schtasks_csv_lossy(text: &str) -> Vec<PersistenceEntry> {
    text.lines()
        .skip(1)
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| {
            let columns = parse_csv_record_lossy(line);
            // schtasks /fo csv /v columns: 0=HostName, 1=TaskName, ...
            let name = columns.get(1)?.to_string();
            let command = columns
                .iter()
                .find(|value| looks_like_windows_command(value))?;
            Some(PersistenceEntry {
                platform: "windows".to_string(),
                source: "Scheduled Task".to_string(),
                name,
                command: command.to_string(),
            })
        })
        .collect()
}

fn parse_csv_record_lossy(line: &str) -> Vec<String> {
    let mut columns = Vec::new();
    let mut field = String::new();
    let mut chars = line.chars().peekable();
    let mut in_quotes = false;
    let mut at_field_start = true;

    while let Some(ch) = chars.next() {
        if in_quotes {
            if ch == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    in_quotes = false;
                }
            } else {
                field.push(ch);
            }
            continue;
        }

        match ch {
            '"' if at_field_start => {
                in_quotes = true;
                at_field_start = false;
            }
            ',' => {
                columns.push(field.trim().to_string());
                field.clear();
                at_field_start = true;
            }
            _ => {
                if !ch.is_whitespace() {
                    at_field_start = false;
                }
                field.push(ch);
            }
        }
    }

    columns.push(field.trim().to_string());
    columns
}

fn looks_like_windows_command(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    [
        ".exe",
        ".bat",
        ".cmd",
        ".ps1",
        ".vbs",
        ".js",
        "powershell",
        "pwsh",
        "cmd",
        "mshta",
        "wscript",
        "cscript",
        "rundll32",
        "regsvr32",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

#[cfg(any(windows, test))]
fn decode_registry_string_lossy(bytes: &[u8]) -> String {
    if bytes.len() >= 2
        && bytes.len().is_multiple_of(2)
        && bytes.chunks_exact(2).any(|chunk| chunk[1] == 0)
    {
        let units = bytes
            .chunks_exact(2)
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .take_while(|unit| *unit != 0)
            .collect::<Vec<_>>();
        return String::from_utf16_lossy(&units);
    }

    String::from_utf8_lossy(bytes)
        .trim_matches('\0')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_windows_task_command() {
        // schtasks /fo csv /v: col0=HostName, col1=TaskName, ...
        let csv =
            "\"HostName\",\"TaskName\",\"Task To Run\"\n\"DESKTOP\",\"\\Updater\",\"powershell.exe -EncodedCommand SQBFAFgA\"\n";
        let entries = parse_schtasks_csv_lossy(csv);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].platform, "windows");
        assert_eq!(entries[0].name, "\\Updater");
    }

    #[test]
    fn parses_schtasks_mshta_launcher_without_exe_suffix() {
        let csv = "\"HostName\",\"TaskName\",\"Task To Run\"\n\"DESKTOP\",\"\\Login\",\"mshta vbscript:Execute(\\\"CreateObject(\\\"\\\"WScript.Shell\\\"\\\").Run \\\"\\\"powershell -w hidden\\\"\\\"\\\")\"\n";
        let entries = parse_schtasks_csv_lossy(csv);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "\\Login");
        assert!(entries[0].command.contains("mshta"));
    }

    #[test]
    fn parses_schtasks_command_with_escaped_quotes_and_comma() {
        let csv = "\"HostName\",\"TaskName\",\"Task To Run\"\n\"DESKTOP\",\"\\Updater\",\"cmd.exe /c payload.exe --names \"\"alpha\"\",\"\"beta\"\"\"\n";
        let entries = parse_schtasks_csv_lossy(csv);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "\\Updater");
        assert_eq!(
            entries[0].command,
            "cmd.exe /c payload.exe --names \"alpha\",\"beta\""
        );
    }

    #[test]
    fn decodes_utf16le_registry_run_value() {
        let mut bytes = Vec::new();
        for unit in "powershell.exe -EncodedCommand SQBFAFgA\0".encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }

        assert_eq!(
            decode_registry_string_lossy(&bytes),
            "powershell.exe -EncodedCommand SQBFAFgA"
        );
    }
}
