#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

root="${PANICSCAN_FEATURE_ROOT:-$(mktemp -d /tmp/panicscan-feature-smoke.XXXXXX)}"
report_json="${PANICSCAN_FEATURE_REPORT_JSON:-$root/report.json}"
report_html="${PANICSCAN_FEATURE_REPORT_HTML:-$root/report.html}"
features_json="${PANICSCAN_FEATURE_JSON:-$root/features.json}"
features_stdout="${PANICSCAN_FEATURE_STDOUT:-$root/features.stdout}"
features_stderr="${PANICSCAN_FEATURE_STDERR:-$root/features.stderr}"
scan_stdout="${PANICSCAN_FEATURE_SCAN_STDOUT:-$root/scan.stdout}"
scan_stderr="${PANICSCAN_FEATURE_SCAN_STDERR:-$root/scan.stderr}"
secret_name="PanicScanFeatureSecretUser"

mkdir -p "$root/$secret_name/Downloads" \
  "$(dirname "$report_json")" \
  "$(dirname "$report_html")" \
  "$(dirname "$features_json")" \
  "$(dirname "$features_stdout")" \
  "$(dirname "$features_stderr")" \
  "$(dirname "$scan_stdout")" \
  "$(dirname "$scan_stderr")"

cat >"$root/$secret_name/Downloads/run.ps1" <<'SCRIPT'
powershell -EncodedCommand SQBFAFgA
SCRIPT

profile="${PANICSCAN_BIN_PROFILE:-debug}"
if [[ -z "${PANICSCAN_BIN:-}" ]]; then
  if [[ "$profile" == "release" ]]; then
    cargo build --release -p panicscan >/dev/null
  else
    cargo build -p panicscan >/dev/null
  fi
fi
bin="$(resolve_panicscan_bin "$profile")"
"$bin" usb "$root/$secret_name" --json "$report_json" --html "$report_html" >"$scan_stdout" 2>"$scan_stderr"
"$bin" features "$report_json" --json "$features_json" >"$features_stdout" 2>"$features_stderr"

scripts/validate_report_schema.sh "$report_json" "$scan_stdout" >/dev/null
scripts/validate_html_offline.sh "$report_html" >/dev/null
scripts/validate_feature_schema.sh "$features_json" "$features_stdout" >/dev/null

python3 - "$features_json" "$features_stdout" "$secret_name" <<'PY'
import json
import pathlib
import sys

features_path = pathlib.Path(sys.argv[1])
stdout_path = pathlib.Path(sys.argv[2])
secret_name = sys.argv[3]

for label, text in [
    ("features_json", features_path.read_text(encoding="utf-8")),
    ("features_stdout", stdout_path.read_text(encoding="utf-8")),
]:
    if secret_name in text or "/Users/" in text or "\\Users\\" in text:
        raise SystemExit(f"{label}: raw user path leaked into feature export")

data = json.loads(features_path.read_text(encoding="utf-8"))
if data["vector_count"] < 1:
    raise SystemExit("expected at least one feature vector")
if not any("script.encoded_command" in vector["evidence_codes"] for vector in data["vectors"]):
    raise SystemExit("expected encoded command evidence code in feature vectors")
if not any(vector["path_extension"] == "ps1" for vector in data["vectors"]):
    raise SystemExit("expected ps1 path extension feature")
PY

echo "feature_export_smoke=passed"
echo "root=$root"
echo "report_json=$report_json"
echo "features_json=$features_json"
