#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

root="${PANICSCAN_REDACTION_ROOT:-target/panicscan-redaction-smoke}"
secret_user="${PANICSCAN_REDACTION_USER:-PanicScanSecretUser}"
scan_root="$root/Users/$secret_user/Downloads"
json_path="${PANICSCAN_REDACTION_JSON:-$root/redaction.json}"
html_path="${PANICSCAN_REDACTION_HTML:-$root/redaction.html}"
stdout_path="${PANICSCAN_REDACTION_STDOUT:-$root/redaction.stdout}"
stderr_path="${PANICSCAN_REDACTION_STDERR:-$root/redaction.stderr}"

mkdir -p "$scan_root" \
  "$(dirname "$json_path")" \
  "$(dirname "$html_path")" \
  "$(dirname "$stdout_path")" \
  "$(dirname "$stderr_path")"

sample="$scan_root/run.ps1"
cat >"$sample" <<'EOF'
powershell.exe -NoProfile -EncodedCommand SQBFAFgA
EOF

"$bin" usb "$root" --json "$json_path" --html "$html_path" >"$stdout_path" 2>"$stderr_path"

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null

python3 - "$json_path" "$html_path" "$stdout_path" "$secret_user" <<'PY'
import json
import pathlib
import sys

json_path = pathlib.Path(sys.argv[1])
html_path = pathlib.Path(sys.argv[2])
stdout_path = pathlib.Path(sys.argv[3])
secret_user = sys.argv[4]

json_text = json_path.read_text(encoding="utf-8")
html_text = html_path.read_text(encoding="utf-8")
stdout_text = stdout_path.read_text(encoding="utf-8")

for label, text in [
    ("json", json_text),
    ("html", html_text),
    ("stdout", stdout_text),
]:
    if secret_user in text:
        raise SystemExit(f"{label} report leaked synthetic username {secret_user}")

report = json.loads(json_text)
stdout_report = json.loads(stdout_text)

if not report.get("findings"):
    raise SystemExit("expected at least one redaction smoke finding")
if not stdout_report.get("findings"):
    raise SystemExit("expected at least one stdout redaction smoke finding")

item_paths = [finding.get("item_path") or "" for finding in report["findings"]]
if not any("/Users/<user>/" in path or "\\Users\\<user>\\" in path for path in item_paths):
    raise SystemExit(f"expected redacted user profile path in JSON item_path, got {item_paths!r}")

stdout_item_paths = [finding.get("item_path") or "" for finding in stdout_report["findings"]]
if not any("/Users/<user>/" in path or "\\Users\\<user>\\" in path for path in stdout_item_paths):
    raise SystemExit(
        f"expected redacted user profile path in stdout item_path, got {stdout_item_paths!r}"
    )

if "&lt;user&gt;" not in html_text and "<user>" not in html_text:
    raise SystemExit("expected redacted user marker in HTML report")

print("report_redaction_smoke=passed")
print(f"findings_count={len(report['findings'])}")
print(f"json={json_path}")
print(f"html={html_path}")
print(f"stdout={stdout_path}")
PY

