use std::collections::BTreeMap;

use crate::report::redaction::redact_report;
use crate::report::ScanReport;

pub fn render_html(report: &ScanReport) -> String {
    let report = redact_report(report);

    // Group findings by title
    let mut groups: BTreeMap<(u8, String), Vec<_>> = BTreeMap::new();
    for finding in &report.findings {
        groups
            .entry((u8::MAX - finding.score, finding.title.clone()))
            .or_default()
            .push(finding);
    }

    let mut sections = String::new();
    for ((_, title), findings) in &groups {
        let explanation = &findings[0].explanation;
        let action = format!("{:?}", findings[0].recommended_action);

        let count = findings.len();
        let mut items = String::new();
        for finding in findings {
            let location = match (
                finding.item_path.as_deref(),
                finding.persistence_location.as_deref(),
                finding.process_id,
            ) {
                (Some(path), _, _) => escape(path),
                (_, Some(loc), _) => escape(loc),
                (_, _, Some(pid)) => format!("Process ID: {pid}"),
                _ => "Unknown".to_string(),
            };
            items.push_str(&format!(
                "<li class=\"item\"><span class=\"location\">{location}</span><span class=\"item-score\">Risk Score: {}</span></li>",
                finding.score
            ));
        }

        sections.push_str(&format!(
            "<section class=\"group\">
  <div class=\"group-header\">
    <span class=\"count\">{count} findings</span>
    <div>
      <h2>{}</h2>
      <p class=\"explanation\">{}</p>
    </div>
  </div>
  <ul class=\"items\">{items}</ul>
  <p class=\"action\">Recommended Action: <strong>{action}</strong></p>
</section>",
            escape(title),
            escape(explanation),
        ));
    }

    let warnings_html = if report.warnings.is_empty() {
        String::new()
    } else {
        let items: String = report
            .warnings
            .iter()
            .map(|w| format!("<li>{}</li>", escape(w)))
            .collect();
        format!("<section class=\"warnings\"><h2>Warnings</h2><ul>{items}</ul></section>")
    };

    let no_findings = if report.findings.is_empty() {
        "<p class=\"clean\">✓ No threats found.</p>"
    } else {
        ""
    };

    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>defense Report</title><style>{CSS}</style></head>\
<body><main>\
<h1>defense Report</h1>\
<div class=\"meta\">\
  <span>Mode: <strong>{:?}</strong></span>\
  <span>Scanned files: <strong>{}</strong></span>\
</div>\
{no_findings}{sections}{warnings_html}\
</main></body></html>",
        report.mode, report.scanned_files,
    )
}

const CSS: &str = r#"
body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:0;background:#f6f7f9;color:#15171a}
main{max-width:960px;margin:0 auto;padding:32px}
h1{font-size:1.6rem;margin-bottom:4px}
h2{font-size:1rem;margin:0;font-weight:600}
.meta{color:#666;font-size:.9rem;margin-bottom:24px;display:flex;gap:16px}
.group{background:#fff;border:1px solid #d8dde5;border-radius:8px;padding:20px;margin:16px 0}
.group-header{display:flex;align-items:flex-start;gap:14px;margin-bottom:12px}
.count{background:#fef3c7;color:#92400e;font-weight:700;font-size:.85rem;padding:4px 8px;border-radius:4px;white-space:nowrap;margin-top:2px}
.item-score{color:#888;font-size:.8rem;margin-left:10px;white-space:nowrap}
.explanation{color:#555;font-size:.9rem;margin:4px 0 0}
.items{margin:8px 0;padding-left:20px}
.item{padding:4px 0;font-size:.9rem;color:#333}
.location{font-family:monospace;font-size:.85rem;word-break:break-all}
.action{margin:12px 0 0;font-size:.85rem;color:#555}
.warnings{background:#fff8e1;border:1px solid #f9c74f;border-radius:8px;padding:16px;margin:16px 0}
.warnings h2{color:#92400e}
.warnings ul{margin:8px 0;padding-left:20px;font-size:.9rem}
.clean{color:#15803d;font-weight:600;font-size:1rem;padding:16px;background:#f0fdf4;border-radius:8px;border:1px solid #86efac}
"#;

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::report::{Finding, FindingSeverity, RecommendedAction};
    use crate::scan::ScanMode;

    fn base_report() -> ScanReport {
        ScanReport {
            schema_version: "1".to_string(),
            app_version: "0.1.0".to_string(),
            mode: ScanMode::Quick,
            started_at: "now".to_string(),
            finished_at: "now".to_string(),
            duration_ms: 1,
            memory_peak_kb: Some(1),
            scanned_files: 0,
            scanned_persistence_entries: 0,
            findings: Vec::new(),
            warnings: Vec::new(),
        }
    }

    #[test]
    fn renders_html_document() {
        assert!(render_html(&base_report()).contains("<!doctype html>"));
    }

    #[test]
    fn html_report_redacts_user_paths() {
        let mut report = base_report();
        report.scanned_files = 1;
        report.findings = vec![Finding {
            id: "finding-1".to_string(),
            severity: FindingSeverity::Medium,
            score: 50,
            title: "Suspicious file".to_string(),
            explanation: "Found under C:\\Users\\Veli\\Downloads".to_string(),
            item_path: Some("C:\\Users\\Veli\\Downloads\\run.ps1".to_string()),
            process_id: None,
            persistence_location: None,
            evidences: Vec::new(),
            recommended_action: RecommendedAction::Review,
        }];

        let html = render_html(&report);
        assert!(!html.contains("Veli"));
        assert!(html.contains("C:\\Users\\&lt;user&gt;\\Downloads\\run.ps1"));
        assert!(html.contains("Location:") || html.contains("location"));
    }
}
