use crate::report::{Evidence, EvidenceKind};

pub fn analyze_autorun_inf(text: &str) -> Vec<Evidence> {
    let lower = text.to_ascii_lowercase();
    let mut evidences = Vec::new();

    if lower.contains("[autorun]") && (lower.contains("open=") || lower.contains("shellexecute=")) {
        evidences.push(Evidence {
            kind: EvidenceKind::Persistence,
            code: "autorun.exec_entry".to_string(),
            title: "Autorun execution entry".to_string(),
            detail: "autorun.inf contains open= or shellexecute= entry".to_string(),
            weight: 25,
        });
    }

    if lower.contains(".exe")
        || lower.contains(".scr")
        || lower.contains(".bat")
        || lower.contains(".cmd")
    {
        evidences.push(Evidence {
            kind: EvidenceKind::File,
            code: "autorun.executable_reference".to_string(),
            title: "Autorun references executable content".to_string(),
            detail: "autorun.inf references executable or script extension".to_string(),
            weight: 20,
        });
    }

    evidences
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_executable_autorun_entry() {
        let text = "[autorun]\nopen=setup.exe\n";
        let evidences = analyze_autorun_inf(text);
        assert_eq!(evidences.len(), 2);
    }
}
