use crate::report::{Evidence, EvidenceKind};

const LAUNCHERS: &[&str] = &[
    "powershell.exe",
    "pwsh.exe",
    "cmd.exe",
    "wscript.exe",
    "cscript.exe",
    "mshta.exe",
    "rundll32.exe",
    "regsvr32.exe",
];

pub fn analyze_lnk_bytes(bytes: &[u8]) -> Vec<Evidence> {
    let text = bytes
        .iter()
        .copied()
        .filter(|byte| byte.is_ascii_graphic() || *byte == b' ')
        .map(char::from)
        .collect::<String>()
        .to_ascii_lowercase();

    let mut evidences = Vec::new();
    for launcher in LAUNCHERS {
        if text.contains(launcher) {
            evidences.push(Evidence {
                kind: EvidenceKind::Shortcut,
                code: "lnk.suspicious_launcher".to_string(),
                title: "Shortcut launches script-capable Windows binary".to_string(),
                detail: format!("Shortcut contains reference to {launcher}"),
                weight: 30,
            });
            break;
        }
    }

    if text.contains("-encodedcommand") || text.contains("http://") || text.contains("https://") {
        evidences.push(Evidence {
            kind: EvidenceKind::Shortcut,
            code: "lnk.suspicious_arguments".to_string(),
            title: "Shortcut contains suspicious command arguments".to_string(),
            detail: "Shortcut contains encoded command or URL-like argument".to_string(),
            weight: 20,
        });
    }

    evidences
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_powershell_lnk_strings() {
        let evidences =
            analyze_lnk_bytes(b"C:\\Windows\\System32\\powershell.exe -EncodedCommand SQBFAFgA");
        assert_eq!(evidences.len(), 2);
    }
}
