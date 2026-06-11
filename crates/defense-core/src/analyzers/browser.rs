use serde_json::Value;

use crate::report::{Evidence, EvidenceKind};

pub fn analyze_extension_manifest(text: &str) -> Vec<Evidence> {
    let Ok(json) = serde_json::from_str::<Value>(text) else {
        return Vec::new();
    };

    let mut evidences = Vec::new();
    let permissions = json
        .get("permissions")
        .and_then(|value| value.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    if permissions.contains(&"<all_urls>") {
        evidences.push(Evidence {
            kind: EvidenceKind::Browser,
            code: "browser.all_urls_permission".to_string(),
            title: "Browser extension can access all sites".to_string(),
            detail: "Manifest requests <all_urls> permission".to_string(),
            weight: 20,
        });
    }

    if permissions.contains(&"webRequest") && permissions.contains(&"webRequestBlocking") {
        evidences.push(Evidence {
            kind: EvidenceKind::Browser,
            code: "browser.request_interception".to_string(),
            title: "Browser extension can intercept requests".to_string(),
            detail: "Manifest requests webRequest and webRequestBlocking".to_string(),
            weight: 25,
        });
    }

    evidences
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_all_urls_permission() {
        let manifest = r#"{"permissions":["<all_urls>","webRequest","webRequestBlocking"]}"#;
        let evidences = analyze_extension_manifest(manifest);
        assert_eq!(evidences.len(), 2);
    }
}
