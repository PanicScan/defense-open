#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

os_name="$(safe_name "$(uname -s)")"
evidence_dir="${PANICSCAN_EVIDENCE_DIR:-/tmp/panicscan-platform-evidence-$os_name}"
logs_dir="$evidence_dir/logs"
reports_dir="$evidence_dir/reports"
dist_root="$evidence_dir/dist"
artifact_name="${PANICSCAN_EVIDENCE_ARTIFACT_NAME:-panicscan-$os_name-evidence}"
summary="$evidence_dir/summary.txt"

mkdir -p "$logs_dir" "$reports_dir" "$dist_root"
: >"$summary"

record() {
  printf '%s=%s\n' "$1" "$2" | tee -a "$summary"
}

run_step() {
  local name="$1"
  shift

  local stdout_path="$logs_dir/$name.stdout"
  local stderr_path="$logs_dir/$name.stderr"
  record "step_${name}" "started"
  if "$@" >"$stdout_path" 2>"$stderr_path"; then
    record "step_${name}" "passed"
  else
    local status="$?"
    record "step_${name}" "failed_$status"
    sed -n '1,120p' "$stdout_path" >&2 || true
    sed -n '1,120p' "$stderr_path" >&2 || true
    exit "$status"
  fi
}

require_nonempty() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "expected non-empty evidence file: $path" >&2
    exit 1
  fi
}

file_size_bytes() {
  local path="$1"
  if stat -f%z "$path" >/dev/null 2>&1; then
    stat -f%z "$path"
  else
    stat -c%s "$path"
  fi
}

dir_size_bytes() {
  local path="$1"
  local size_kb
  size_kb="$(du -sk "$path" | awk '{ print $1 }')"
  printf '%s\n' "$((size_kb * 1024))"
}

{
  printf 'date_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'uname_s=%s\n' "$(uname -s)"
  printf 'uname_m=%s\n' "$(uname -m)"
  printf 'uname_a=%s\n' "$(uname -a)"
  if command -v sw_vers >/dev/null 2>&1; then
    sw_vers
  fi
  if [[ -f /etc/os-release ]]; then
    cat /etc/os-release
  fi
  if command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe /c ver
  fi
  if command -v rustc >/dev/null 2>&1; then
    rustc --version
  fi
  if command -v cargo >/dev/null 2>&1; then
    cargo --version
  fi
} >"$evidence_dir/platform.txt" 2>"$logs_dir/platform.stderr" || true

record "evidence_dir" "$evidence_dir"
record "artifact_name" "$artifact_name"

run_step "build_release" cargo build --release -p panicscan
bin="$(resolve_panicscan_bin release)"
record "release_binary" "$bin"

run_step "quick_scan" "$bin" quick \
  --json "$reports_dir/quick.json" \
  --html "$reports_dir/quick.html"
require_nonempty "$reports_dir/quick.json"
require_nonempty "$reports_dir/quick.html"
run_step "validate_quick_schema" scripts/validate_report_schema.sh \
  "$reports_dir/quick.json" \
  "$logs_dir/quick_scan.stdout"
run_step "validate_quick_html_offline" scripts/validate_html_offline.sh \
  "$reports_dir/quick.html"

run_step "report_redaction_smoke" env \
  PANICSCAN_REDACTION_ROOT="$evidence_dir/report-redaction" \
  PANICSCAN_REDACTION_JSON="$reports_dir/redaction.json" \
  PANICSCAN_REDACTION_HTML="$reports_dir/redaction.html" \
  PANICSCAN_REDACTION_STDOUT="$logs_dir/redaction.stdout" \
  PANICSCAN_REDACTION_STDERR="$logs_dir/redaction.stderr" \
  scripts/report_redaction_smoke.sh
require_nonempty "$reports_dir/redaction.json"
require_nonempty "$reports_dir/redaction.html"

run_step "progress_latency_smoke" env \
  PANICSCAN_PROGRESS_ROOT="$evidence_dir/progress-latency" \
  PANICSCAN_PROGRESS_JSON="$reports_dir/progress-latency.json" \
  PANICSCAN_PROGRESS_HTML="$reports_dir/progress-latency.html" \
  PANICSCAN_PROGRESS_STDOUT="$logs_dir/progress-latency.stdout" \
  PANICSCAN_PROGRESS_STDERR="$logs_dir/progress-latency.stderr" \
  scripts/progress_latency_smoke.sh
require_nonempty "$reports_dir/progress-latency.json"
require_nonempty "$reports_dir/progress-latency.html"

run_step "quick_memory_smoke" env \
  PANICSCAN_MEM_JSON="$reports_dir/quick-memory.json" \
  PANICSCAN_MEM_HTML="$reports_dir/quick-memory.html" \
  PANICSCAN_MEM_STDOUT="$logs_dir/quick-memory.stdout" \
  PANICSCAN_MEM_STDERR="$logs_dir/quick-memory.stderr" \
  scripts/perf_quick_memory_smoke.sh
require_nonempty "$reports_dir/quick-memory.json"
require_nonempty "$reports_dir/quick-memory.html"

run_step "full_budget_smoke" env \
  PANICSCAN_FULL_BUDGET_JSON="$reports_dir/full-budget.json" \
  PANICSCAN_FULL_BUDGET_HTML="$reports_dir/full-budget.html" \
  PANICSCAN_FULL_BUDGET_STDOUT="$logs_dir/full-budget.stdout" \
  PANICSCAN_FULL_BUDGET_STDERR="$logs_dir/full-budget.stderr" \
  PANICSCAN_BIN="$bin" \
  scripts/full_budget_smoke.sh
require_nonempty "$reports_dir/full-budget.json"
require_nonempty "$reports_dir/full-budget.html"

run_step "miner_process_smoke" env \
  PANICSCAN_MINER_PROCESS_ROOT="$evidence_dir/miner-process" \
  PANICSCAN_MINER_PROCESS_JSON="$reports_dir/miner-process.json" \
  PANICSCAN_MINER_PROCESS_HTML="$reports_dir/miner-process.html" \
  PANICSCAN_MINER_PROCESS_STDOUT="$logs_dir/miner-process.stdout" \
  PANICSCAN_MINER_PROCESS_STDERR="$logs_dir/miner-process.stderr" \
  scripts/miner_process_smoke.sh
require_nonempty "$reports_dir/miner-process.json"
require_nonempty "$reports_dir/miner-process.html"

run_step "no_background_process_smoke" env \
  PANICSCAN_BACKGROUND_ROOT="$evidence_dir/no-background-process" \
  PANICSCAN_BACKGROUND_JSON="$reports_dir/no-background.json" \
  PANICSCAN_BACKGROUND_HTML="$reports_dir/no-background.html" \
  PANICSCAN_BACKGROUND_STDOUT="$logs_dir/no-background.stdout" \
  PANICSCAN_BACKGROUND_STDERR="$logs_dir/no-background.stderr" \
  scripts/no_background_process_smoke.sh
require_nonempty "$reports_dir/no-background.json"
require_nonempty "$reports_dir/no-background.html"

run_step "no_upload_static_audit" scripts/no_upload_static_audit.sh

run_step "portability_contract_audit" scripts/portability_contract_audit.sh

run_step "ai_safety_contract_audit" scripts/ai_safety_contract_audit.sh

run_step "feature_export_smoke" env \
  PANICSCAN_FEATURE_ROOT="$evidence_dir/feature-export" \
  PANICSCAN_FEATURE_REPORT_JSON="$reports_dir/feature-source.json" \
  PANICSCAN_FEATURE_REPORT_HTML="$reports_dir/feature-source.html" \
  PANICSCAN_FEATURE_JSON="$reports_dir/feature-export.json" \
  PANICSCAN_FEATURE_STDOUT="$logs_dir/feature-export.stdout" \
  PANICSCAN_FEATURE_STDERR="$logs_dir/feature-export.stderr" \
  PANICSCAN_FEATURE_SCAN_STDOUT="$logs_dir/feature-scan.stdout" \
  PANICSCAN_FEATURE_SCAN_STDERR="$logs_dir/feature-scan.stderr" \
  PANICSCAN_BIN="$bin" \
  scripts/feature_export_smoke.sh
require_nonempty "$reports_dir/feature-source.json"
require_nonempty "$reports_dir/feature-source.html"
require_nonempty "$reports_dir/feature-export.json"

run_step "system_critical_policy_smoke" env \
  PANICSCAN_SYSTEM_CRITICAL_STDOUT="$logs_dir/system-critical-policy.stdout" \
  PANICSCAN_SYSTEM_CRITICAL_STDERR="$logs_dir/system-critical-policy.stderr" \
  scripts/system_critical_policy_smoke.sh

run_step "usb_10k_smoke" env \
  PANICSCAN_PERF_ROOT="$evidence_dir/synthetic-usb10k" \
  PANICSCAN_PERF_JSON="$reports_dir/usb10k.json" \
  PANICSCAN_PERF_HTML="$reports_dir/usb10k.html" \
  PANICSCAN_PERF_STDOUT="$logs_dir/usb10k.stdout" \
  PANICSCAN_PERF_STDERR="$logs_dir/usb10k.stderr" \
  scripts/perf_usb_10k_smoke.sh
require_nonempty "$reports_dir/usb10k.json"
require_nonempty "$reports_dir/usb10k.html"

run_step "usb_detection_smoke" env \
  PANICSCAN_USB_DETECTION_ROOT="$evidence_dir/usb-detection" \
  PANICSCAN_USB_DETECTION_JSON="$reports_dir/usb-detection.json" \
  PANICSCAN_USB_DETECTION_HTML="$reports_dir/usb-detection.html" \
  PANICSCAN_USB_DETECTION_STDOUT="$logs_dir/usb-detection.stdout" \
  PANICSCAN_USB_DETECTION_STDERR="$logs_dir/usb-detection.stderr" \
  scripts/usb_detection_smoke.sh
require_nonempty "$reports_dir/usb-detection.json"
require_nonempty "$reports_dir/usb-detection.html"

run_step "quarantine_roundtrip_smoke" env \
  PANICSCAN_QUARANTINE_SMOKE_ROOT="$evidence_dir/quarantine-roundtrip" \
  scripts/quarantine_roundtrip_smoke.sh

run_step "quarantine_confirmation_smoke" env \
  PANICSCAN_CONFIRMATION_ROOT="$evidence_dir/quarantine-confirmation" \
  scripts/quarantine_confirmation_smoke.sh

run_step "package_release" env \
  PANICSCAN_ARTIFACT_NAME="$artifact_name" \
  PANICSCAN_BINARY_PATH="$bin" \
  PANICSCAN_DIST_ROOT="$dist_root" \
  scripts/package_release.sh

artifact_dir="$dist_root/$artifact_name"
record "artifact_dir" "$artifact_dir"

run_step "sign_release_artifact" env \
  PANICSCAN_ARTIFACT_DIR="$artifact_dir" \
  scripts/sign_release_artifact.sh

run_step "verify_checksums" scripts/verify_checksums.sh "$artifact_dir/SHA256SUMS.txt"

run_step "verify_release_signatures" env \
  PANICSCAN_ARTIFACT_DIR="$artifact_dir" \
  scripts/verify_release_signatures.sh

run_step "release_artifact_smoke" env \
  PANICSCAN_ARTIFACT_DIR="$artifact_dir" \
  PANICSCAN_ARTIFACT_SMOKE_ROOT="$evidence_dir/artifact-smoke" \
  scripts/release_artifact_smoke.sh
require_nonempty "$evidence_dir/artifact-smoke/quick.json"
require_nonempty "$evidence_dir/artifact-smoke/usb.json"

quick_duration_ms="$(awk -F': ' '/"duration_ms"/ { gsub(/,/, "", $2); print $2; exit }' "$reports_dir/quick.json")"
quick_memory_kb="$(awk -F': ' '/"memory_peak_kb"/ { gsub(/,/, "", $2); print $2; exit }' "$reports_dir/quick-memory.json")"
full_budget_duration_ms="$(awk -F': ' '/"duration_ms"/ { gsub(/,/, "", $2); print $2; exit }' "$reports_dir/full-budget.json")"
release_binary_size_bytes="$(file_size_bytes "$bin")"
artifact_dir_size_bytes="$(dir_size_bytes "$artifact_dir")"
progress_latency_ms="$(awk -F= '/^progress_latency_ms=/ { print $2; exit }' "$logs_dir/progress_latency_smoke.stdout")"
background_process_check="$(awk -F= '/^background_process_check=/ { print $2; exit }' "$logs_dir/no_background_process_smoke.stdout")"
no_upload_static_audit="$(awk -F= '/^no_upload_static_audit=/ { print $2; exit }' "$logs_dir/no_upload_static_audit.stdout")"
portability_contract_audit="$(awk -F= '/^portability_contract_audit=/ { print $2; exit }' "$logs_dir/portability_contract_audit.stdout")"
ai_safety_contract_audit="$(awk -F= '/^ai_safety_contract_audit=/ { print $2; exit }' "$logs_dir/ai_safety_contract_audit.stdout")"
feature_export_smoke="$(awk -F= '/^feature_export_smoke=/ { print $2; exit }' "$logs_dir/feature_export_smoke.stdout")"
system_critical_policy_smoke="$(awk -F= '/^system_critical_policy_smoke=/ { print $2; exit }' "$logs_dir/system_critical_policy_smoke.stdout")"
report_redaction_smoke="$(awk -F= '/^report_redaction_smoke=/ { print $2; exit }' "$logs_dir/report_redaction_smoke.stdout")"
miner_process_smoke="$(awk -F= '/^miner_process_smoke=/ { print $2; exit }' "$logs_dir/miner_process_smoke.stdout")"
usb_detection_smoke="$(awk -F= '/^usb_detection_smoke=/ { print $2; exit }' "$logs_dir/usb_detection_smoke.stdout")"
quarantine_confirmation_smoke="$(awk -F= '/^quarantine_confirmation_smoke=/ { print $2; exit }' "$logs_dir/quarantine_confirmation_smoke.stdout")"
usb10k_duration_ms="$(awk -F': ' '/"duration_ms"/ { gsub(/,/, "", $2); print $2; exit }' "$reports_dir/usb10k.json")"

record "quick_duration_ms" "${quick_duration_ms:-unknown}"
record "quick_memory_kb" "${quick_memory_kb:-unknown}"
record "full_budget_duration_ms" "${full_budget_duration_ms:-unknown}"
record "release_binary_size_bytes" "${release_binary_size_bytes:-unknown}"
record "release_binary_max_bytes" "${PANICSCAN_RELEASE_BINARY_MAX_BYTES:-52428800}"
record "artifact_dir_size_bytes" "${artifact_dir_size_bytes:-unknown}"
record "artifact_dir_max_bytes" "${PANICSCAN_ARTIFACT_DIR_MAX_BYTES:-104857600}"
record "progress_latency_ms" "${progress_latency_ms:-unknown}"
record "background_process_check" "${background_process_check:-unknown}"
record "no_upload_static_audit" "${no_upload_static_audit:-unknown}"
record "portability_contract_audit" "${portability_contract_audit:-unknown}"
record "ai_safety_contract_audit" "${ai_safety_contract_audit:-unknown}"
record "feature_export_smoke" "${feature_export_smoke:-unknown}"
record "system_critical_policy_smoke" "${system_critical_policy_smoke:-unknown}"
record "report_redaction_smoke" "${report_redaction_smoke:-unknown}"
record "miner_process_smoke" "${miner_process_smoke:-unknown}"
record "usb_detection_smoke" "${usb_detection_smoke:-unknown}"
record "quarantine_confirmation_smoke" "${quarantine_confirmation_smoke:-unknown}"
record "usb10k_duration_ms" "${usb10k_duration_ms:-unknown}"
record "status" "passed"

cat "$summary"
