use std::fs;

use defense_core::{ScanMode, ScanRequest, ScanRunner};

#[test]
fn quick_scan_handles_synthetic_tree_and_finds_script() {
    let dir = tempfile::tempdir().unwrap();
    for index in 0..1_000 {
        fs::write(dir.path().join(format!("file-{index}.txt")), b"clean").unwrap();
    }
    let script_path = dir.path().join("run.ps1");
    fs::write(&script_path, "powershell -EncodedCommand SQBFAFgA").unwrap();

    let report = ScanRunner::default()
        .run(ScanRequest::new(ScanMode::Usb).with_root(dir.path().display().to_string()))
        .unwrap();

    assert_eq!(report.scanned_files, 1);
    let script_path_string = script_path.display().to_string();
    assert!(report.findings.iter().any(|finding| {
        finding.item_path.as_deref() == Some(script_path_string.as_str())
            && finding
                .evidences
                .iter()
                .any(|evidence| evidence.code == "script.encoded_command")
    }));
    assert!(report.memory_peak_kb.unwrap() > 0);
}

#[test]
fn scan_runs_to_completion_and_produces_no_time_budget_warnings() {
    // Previously max_minutes could cut the scan short.  The scanner now runs
    // until every file is analysed regardless of elapsed time.
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.ps1"), "powershell -enc SQBFAFgA").unwrap();
    fs::write(dir.path().join("b.ps1"), "powershell -enc SQBFAFgA").unwrap();
    fs::write(dir.path().join("c.ps1"), "powershell -enc SQBFAFgA").unwrap();

    let report = ScanRunner::default()
        .run(ScanRequest::new(ScanMode::Usb).with_root(dir.path().display().to_string()))
        .unwrap();

    // All three scripts must be analysed — no early cutoff.
    assert_eq!(report.scanned_files, 3, "all files must be scanned");
    // At least one file finding per script (persistence/process may add more)
    let file_findings = report
        .findings
        .iter()
        .filter(|f| f.item_path.is_some())
        .count();
    assert!(
        file_findings >= 3,
        "every script must produce a file finding (got {file_findings})"
    );
    assert!(
        report.warnings.iter().all(|w| !w.contains("time budget")),
        "no time-budget warnings expected: {:?}",
        report.warnings
    );
}
