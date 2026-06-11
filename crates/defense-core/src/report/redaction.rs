use crate::report::{Finding, ScanReport};

pub fn redact_report(report: &ScanReport) -> ScanReport {
    let mut redacted = report.clone();
    redacted.findings = redacted.findings.into_iter().map(redact_finding).collect();
    redacted.warnings = redacted
        .warnings
        .into_iter()
        .map(|warning| redact_report_text(&warning))
        .collect();
    redacted
}

fn redact_finding(mut finding: Finding) -> Finding {
    finding.title = redact_report_text(&finding.title);
    finding.explanation = redact_report_text(&finding.explanation);
    finding.item_path = finding.item_path.map(|path| redact_report_text(&path));
    finding.persistence_location = finding
        .persistence_location
        .map(|location| redact_report_text(&location));
    finding.evidences = finding
        .evidences
        .into_iter()
        .map(|mut evidence| {
            evidence.title = redact_report_text(&evidence.title);
            evidence.detail = redact_report_text(&evidence.detail);
            evidence
        })
        .collect();
    finding
}

pub fn redact_report_text(input: &str) -> String {
    redact_common_secrets(&redact_username_paths(input))
}

pub fn redact_username_paths(input: &str) -> String {
    ["/Users/", "\\Users\\", "/home/", "\\home\\"]
        .iter()
        .fold(input.to_string(), |redacted, marker| {
            redact_segment_after_marker(&redacted, marker)
        })
}

pub fn redact_common_secrets(input: &str) -> String {
    let parts = input.split_whitespace().collect::<Vec<_>>();
    let mut redacted = Vec::with_capacity(parts.len());
    let mut redact_next_bearer_value = false;

    for part in parts {
        let lower = part.to_ascii_lowercase();
        if redact_next_bearer_value {
            redacted.push("<redacted>");
            redact_next_bearer_value = false;
            continue;
        }

        if lower == "bearer" {
            redacted.push(part);
            redact_next_bearer_value = true;
            continue;
        }

        if lower.contains("token=") || lower.contains("api_key=") || lower.contains("password=") {
            redacted.push("<redacted>");
        } else {
            redacted.push(part);
        }
    }

    redacted.join(" ")
}

fn redact_segment_after_marker(input: &str, marker: &str) -> String {
    let lower_input = input.to_ascii_lowercase();
    let lower_marker = marker.to_ascii_lowercase();
    let mut output = String::with_capacity(input.len());
    let mut cursor = 0;

    while let Some(relative_index) = lower_input[cursor..].find(&lower_marker) {
        let marker_index = cursor + relative_index;
        let username_start = marker_index + marker.len();
        let rest = &input[username_start..];
        let username_len = rest
            .find(|ch: char| {
                ch == '/'
                    || ch == '\\'
                    || ch.is_whitespace()
                    || ch == '"'
                    || ch == '\''
                    || ch == ':'
                    || ch == ';'
                    || ch == ','
            })
            .unwrap_or(rest.len());

        if username_len == 0 {
            output.push_str(&input[cursor..username_start]);
            cursor = username_start;
            continue;
        }

        output.push_str(&input[cursor..username_start]);
        output.push_str("<user>");
        cursor = username_start + username_len;
    }

    output.push_str(&input[cursor..]);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_windows_username() {
        let result = redact_username_paths("C:\\Users\\Ali\\Downloads\\a.exe");
        assert_eq!(result, "C:\\Users\\<user>\\Downloads\\a.exe");
    }

    #[test]
    fn redacts_unix_profile_paths_without_changing_separators() {
        let result = redact_username_paths("/Users/Ali/Downloads/a.sh and /home/veli/.config/app");
        assert_eq!(
            result,
            "/Users/<user>/Downloads/a.sh and /home/<user>/.config/app"
        );
    }

    #[test]
    fn redacts_token_argument() {
        let result = redact_common_secrets("app.exe token=abc123");
        assert_eq!(result, "app.exe <redacted>");
    }

    #[test]
    fn redacts_authorization_bearer_value() {
        let result = redact_common_secrets("curl -H Authorization: Bearer abc123 https://x");
        assert_eq!(result, "curl -H Authorization: Bearer <redacted> https://x");
    }
}
