#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

json_path="${PANICSCAN_MEM_JSON:-/tmp/panicscan-quick-memory.json}"
html_path="${PANICSCAN_MEM_HTML:-/tmp/panicscan-quick-memory.html}"
stdout_path="${PANICSCAN_MEM_STDOUT:-/tmp/panicscan-quick-memory.stdout}"
stderr_path="${PANICSCAN_MEM_STDERR:-/tmp/panicscan-quick-memory.stderr}"
max_kb="${PANICSCAN_MEM_MAX_KB:-307200}"
max_duration_ms="${PANICSCAN_QUICK_MAX_MS:-120000}"

# Cap the scan at 2 minutes so this smoke test completes on CI runners that
# have large Temp directories (e.g. Windows GitHub Actions).  Real interactive
# use has no time limit (PANICSCAN_SCAN_MAX_MINUTES is unset by default).
export PANICSCAN_SCAN_MAX_MINUTES="${PANICSCAN_SCAN_MAX_MINUTES:-2}"

"$bin" quick --json "$json_path" --html "$html_path" >"$stdout_path" 2>"$stderr_path"

if [[ ! -s "$json_path" || ! -s "$html_path" ]]; then
  echo "expected non-empty JSON and HTML reports" >&2
  exit 1
fi

if ! grep -q 'panicscan: starting Quick scan' "$stderr_path"; then
  echo "expected progress message in stderr" >&2
  exit 1
fi

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null

duration_ms="$(awk -F': ' '/"duration_ms"/ { gsub(/,/, "", $2); print $2; exit }' "$json_path")"
if [[ -z "$duration_ms" ]]; then
  echo "could not read duration_ms from $json_path" >&2
  exit 1
fi

if [[ "$duration_ms" -gt "$max_duration_ms" ]]; then
  echo "quick scan exceeded ${max_duration_ms}ms: ${duration_ms}ms" >&2
  exit 1
fi

max_rss_kb="$(awk -F': ' '/"memory_peak_kb"/ { gsub(/,/, "", $2); print $2; exit }' "$json_path")"
if [[ -z "$max_rss_kb" || "$max_rss_kb" == "null" ]]; then
  echo "could not read memory_peak_kb from $json_path" >&2
  exit 1
fi

if [[ "$max_rss_kb" -gt "$max_kb" ]]; then
  echo "quick scan exceeded ${max_kb}KB RSS: ${max_rss_kb}KB" >&2
  exit 1
fi

max_rss_mb="$(( (max_rss_kb + 1023) / 1024 ))"
cat <<SUMMARY
duration_ms=$duration_ms
max_duration_ms=$max_duration_ms
max_rss_kb=$max_rss_kb
max_rss_mb=$max_rss_mb
json=$json_path
html=$html_path
stdout=$stdout_path
stderr=$stderr_path
SUMMARY
