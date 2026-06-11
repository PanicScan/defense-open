use std::fs;
use std::path::Path;

use uuid::Uuid;

use crate::analyzers::{autorun, browser, executable, lnk, script};
use crate::collectors::filesystem::FileItem;
use crate::report::{Finding, RecommendedAction};
use crate::rules::RuleEngine;
use crate::scan::scoring::score_evidence;

pub fn analyze_file(item: &FileItem) -> Option<Finding> {
    analyze_file_with_rules(item, &RuleEngine::builtin())
}

pub fn analyze_file_with_rules(item: &FileItem, rule_engine: &RuleEngine) -> Option<Finding> {
    let path = &item.path;
    let bytes = fs::read(path).ok()?;
    analyze_file_bytes_for_path(path, &bytes, rule_engine)
}

fn analyze_file_bytes_for_path(
    path: &Path,
    bytes: &[u8],
    rule_engine: &RuleEngine,
) -> Option<Finding> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let mut evidences = match extension.as_str() {
        "ps1" | "bat" | "cmd" | "vbs" | "js" | "jse" | "wsf" | "hta" | "sh" | "command"
        | "desktop" | "service" => {
            let text = String::from_utf8_lossy(bytes);
            script::analyze_script_text(&text)
        }
        "inf" if file_name_eq(path, "autorun.inf") => {
            let text = String::from_utf8_lossy(bytes);
            let mut evidences = autorun::analyze_autorun_inf(&text);
            evidences.extend(script::analyze_script_text(&text));
            evidences
        }
        "json" if file_name_eq(path, "manifest.json") => {
            let text = String::from_utf8_lossy(bytes);
            browser::analyze_extension_manifest(&text)
        }
        "lnk" => lnk::analyze_lnk_bytes(bytes),
        "exe" | "dll" | "scr" | "com" | "dylib" | "so" | "bin" => {
            executable::analyze_executable_bytes(bytes)
        }
        "" if looks_like_executable(bytes) => executable::analyze_executable_bytes(bytes),
        _ => Vec::new(),
    };
    evidences.extend(rule_engine.scan_bytes(path, bytes));

    if evidences.is_empty() {
        return None;
    }

    let (score, severity, action) = score_evidence(&evidences, is_system_critical_path(path));
    if action == RecommendedAction::Ignore {
        return None;
    }

    Some(Finding {
        id: Uuid::new_v4().to_string(),
        severity,
        score,
        title: "Suspicious file behavior".to_string(),
        explanation: "The file contains patterns commonly used by USB malware, script droppers, miners, or persistence launchers.".to_string(),
        item_path: Some(path.display().to_string()),
        process_id: None,
        persistence_location: None,
        evidences,
        recommended_action: action,
    })
}

fn file_name_eq(path: &Path, expected: &str) -> bool {
    path.file_name()
        .and_then(|value| value.to_str())
        .map(|value| value.eq_ignore_ascii_case(expected))
        .unwrap_or(false)
}

fn looks_like_executable(bytes: &[u8]) -> bool {
    bytes.starts_with(b"MZ")
        || bytes.starts_with(b"\x7fELF")
        || bytes.starts_with(&[0xfe, 0xed, 0xfa, 0xce])
        || bytes.starts_with(&[0xfe, 0xed, 0xfa, 0xcf])
        || bytes.starts_with(&[0xcf, 0xfa, 0xed, 0xfe])
        || bytes.starts_with(&[0xca, 0xfe, 0xba, 0xbe])
}

fn is_system_critical_path(path: &Path) -> bool {
    let normalized = path
        .display()
        .to_string()
        .replace('\\', "/")
        .to_ascii_lowercase();
    let protected_prefixes = [
        "c:/windows/",
        "/system/",
        "/usr/bin/",
        "/usr/sbin/",
        "/bin/",
        "/sbin/",
    ];

    !normalized.starts_with("/system/volumes/data/")
        && protected_prefixes
            .iter()
            .any(|prefix| normalized.starts_with(prefix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_finding_for_encoded_script() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run.ps1");
        fs::write(&path, "powershell -EncodedCommand SQBFAFgA").unwrap();
        let item = FileItem {
            path,
            size: 32,
            modified: None,
        };
        let finding = analyze_file(&item).unwrap();
        assert!(finding.score >= 20);
    }

    #[test]
    fn creates_finding_for_autorun_inf() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("autorun.inf");
        fs::write(&path, "[autorun]\nopen=setup.exe\n").unwrap();
        let item = FileItem {
            path,
            size: 27,
            modified: None,
        };
        let finding = analyze_file(&item).unwrap();
        assert!(finding.score >= 40);
    }

    #[test]
    fn wires_browser_manifest_analysis() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("manifest.json");
        fs::write(
            &path,
            r#"{"permissions":["<all_urls>","webRequest","webRequestBlocking"]}"#,
        )
        .unwrap();
        let item = FileItem {
            path,
            size: 68,
            modified: None,
        };

        let finding = analyze_file(&item).unwrap();

        assert!(finding
            .evidences
            .iter()
            .any(|evidence| evidence.code == "browser.all_urls_permission"));
        assert!(finding.score >= 40);
    }

    #[test]
    fn wires_builtin_rule_engine_analysis() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("miner.ps1");
        fs::write(
            &path,
            "powershell -EncodedCommand SQBFAFgA\n$pool='stratum+tcp://pool.example:3333'",
        )
        .unwrap();
        let item = FileItem {
            path,
            size: 78,
            modified: None,
        };

        let finding = analyze_file(&item).unwrap();

        assert!(finding
            .evidences
            .iter()
            .any(|evidence| evidence.code == "rule.miner-pool-string"));
    }

    #[test]
    fn system_critical_file_policy_uses_manual_review() {
        let finding = analyze_file_bytes_for_path(
            Path::new("/System/Library/Scripts/suspicious.ps1"),
            b"powershell -EncodedCommand SQBFAFgA\nstratum+tcp://pool.example:3333",
            &RuleEngine::builtin(),
        )
        .unwrap();

        assert_eq!(
            finding.recommended_action,
            RecommendedAction::ManualExpertReview
        );
        assert!(finding.score <= 79);
    }

    #[test]
    fn shell_test_e_does_not_trigger_encoded_powershell_finding() {
        let finding = analyze_file_bytes_for_path(
            Path::new("/usr/libexec/postfix/mk_postfix_spool.sh"),
            br#"
            #!/bin/sh
            if [ ! -e "$_socket_path" ] ; then
                /usr/libexec/postfix/bind_unix_socket "$_socket_path"
            fi
            "#,
            &RuleEngine::builtin(),
        );

        assert!(finding.is_none());
    }
}
