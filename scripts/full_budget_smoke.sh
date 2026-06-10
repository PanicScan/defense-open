#!/usr/bin/env bash
# Smoke test for "panicscan full" mode.
#
# Runs a full scan and verifies it produces valid JSON + HTML reports within a
# reasonable wall-clock limit.  The scan is capped by PANICSCAN_SCAN_MAX_MINUTES
# (set to "2" at the CI job level) so it terminates quickly on CI runners.
# In local interactive use there is no limit unless the user sets the env var.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

json_path="${PANICSCAN_FULL_BUDGET_JSON:-/tmp/panicscan-full-budget.json}"
html_path="${PANICSCAN_FULL_BUDGET_HTML:-/tmp/panicscan-full-budget.html}"
stdout_path="${PANICSCAN_FULL_BUDGET_STDOUT:-/tmp/panicscan-full-budget.stdout}"
stderr_path="${PANICSCAN_FULL_BUDGET_STDERR:-/tmp/panicscan-full-budget.stderr}"
# Wall-clock limit: 90 s gives a 30 s buffer over the 1-minute scan cap below.
max_seconds="${PANICSCAN_FULL_BUDGET_MAX_SECONDS:-90}"
# Minutes to pass to the binary via --max-minutes.  Overridable for local use.
scan_max_minutes="${PANICSCAN_FULL_BUDGET_MAX_MINUTES:-1}"

bin="${PANICSCAN_BIN:-$(resolve_panicscan_bin debug)}"

mkdir -p "$(dirname "$json_path")" "$(dirname "$html_path")" "$(dirname "$stdout_path")" "$(dirname "$stderr_path")"

started_epoch="$(date +%s)"
"$bin" full --max-minutes "$scan_max_minutes" --json "$json_path" --html "$html_path" >"$stdout_path" 2>"$stderr_path"
finished_epoch="$(date +%s)"
wall_seconds=$((finished_epoch - started_epoch))

for path in "$json_path" "$html_path" "$stdout_path" "$stderr_path"; do
  if [[ ! -s "$path" ]]; then
    echo "expected non-empty full scan output: $path" >&2
    exit 1
  fi
done

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null

if [[ "$wall_seconds" -gt "$max_seconds" ]]; then
  echo "full scan exceeded wall-clock limit: ${wall_seconds}s > ${max_seconds}s" >&2
  exit 1
fi

if ! grep -q 'panicscan: starting Full scan' "$stderr_path"; then
  echo "expected full scan progress message in stderr" >&2
  exit 1
fi

python3 - "$json_path" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if report.get("mode") != "Full":
    raise SystemExit(f"expected mode=Full, got {report.get('mode')!r}")
duration_ms = report.get("duration_ms")
if not isinstance(duration_ms, int):
    raise SystemExit(f"expected numeric duration_ms, got {duration_ms!r}")
print(f"full_scan_duration_ms={duration_ms}")
PY

cat <<SUMMARY
full_budget_smoke=passed
binary=$bin
json=$json_path
html=$html_path
stdout=$stdout_path
stderr=$stderr_path
wall_seconds=$wall_seconds
SUMMARY
