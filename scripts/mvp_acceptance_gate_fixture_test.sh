#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_MVP_GATE_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-mvp-gate-fixture.XXXXXX)}"
physical="$root/physical-usb"
bad_physical_report="$root/bad-physical-report"
bad_physical_detector="$root/bad-physical-detector"
missing_local_log="$root/missing-local-log"
missing_local_signature_step="$root/missing-local-signature-step"
oversize_local_binary="$root/oversize-local-binary"
output="$root/mvp-gate.out"

write_local_platform_logs() {
  local dir="$1"
  local name
  for name in \
    platform.stderr \
    build_release.stdout build_release.stderr \
    quick_scan.stdout quick_scan.stderr \
    validate_quick_schema.stdout validate_quick_schema.stderr \
    validate_quick_html_offline.stdout validate_quick_html_offline.stderr \
    report_redaction_smoke.stdout report_redaction_smoke.stderr \
    redaction.stdout redaction.stderr \
    progress_latency_smoke.stdout progress_latency_smoke.stderr \
    progress-latency.stdout progress-latency.stderr \
    quick_memory_smoke.stdout quick_memory_smoke.stderr \
    quick-memory.stdout quick-memory.stderr \
    full_budget_smoke.stdout full_budget_smoke.stderr \
    full-budget.stdout full-budget.stderr \
    miner_process_smoke.stdout miner_process_smoke.stderr \
    miner-process.stdout miner-process.stderr \
    no_background_process_smoke.stdout no_background_process_smoke.stderr \
    no-background.stdout no-background.stderr \
    no_upload_static_audit.stdout no_upload_static_audit.stderr \
    portability_contract_audit.stdout portability_contract_audit.stderr \
    ai_safety_contract_audit.stdout ai_safety_contract_audit.stderr \
    feature_export_smoke.stdout feature_export_smoke.stderr \
    feature-export.stdout feature-export.stderr \
    feature-scan.stdout feature-scan.stderr \
    system_critical_policy_smoke.stdout system_critical_policy_smoke.stderr \
    system-critical-policy.stdout system-critical-policy.stderr \
    usb_10k_smoke.stdout usb_10k_smoke.stderr \
    usb10k.stdout usb10k.stderr \
    usb_detection_smoke.stdout usb_detection_smoke.stderr \
    usb-detection.stdout usb-detection.stderr \
    quarantine_roundtrip_smoke.stdout quarantine_roundtrip_smoke.stderr \
    quarantine_confirmation_smoke.stdout quarantine_confirmation_smoke.stderr \
    package_release.stdout package_release.stderr \
    sign_release_artifact.stdout sign_release_artifact.stderr \
    verify_checksums.stdout verify_checksums.stderr \
    verify_release_signatures.stdout verify_release_signatures.stderr \
    release_artifact_smoke.stdout release_artifact_smoke.stderr
  do
    printf 'fixture local log: %s\n' "$name" >"$dir/logs/$name"
  done
}

write_local_platform_reports() {
  local dir="$1"
  local name
  for name in \
    quick.json quick.html \
    quick-memory.json quick-memory.html \
    full-budget.json full-budget.html \
    usb10k.json usb10k.html \
    usb-detection.json usb-detection.html \
    feature-source.json feature-source.html feature-export.json
  do
    printf '{}\n' >"$dir/reports/$name"
  done
}

make_local_platform_evidence() {
  local dir="$1"
  mkdir -p "$dir/logs" "$dir/reports" "$dir/quarantine-roundtrip"
  cat >"$dir/summary.txt" <<'SUMMARY'
step_build_release=passed
step_quick_scan=passed
step_validate_quick_schema=passed
step_validate_quick_html_offline=passed
step_report_redaction_smoke=passed
step_progress_latency_smoke=passed
step_quick_memory_smoke=passed
step_full_budget_smoke=passed
step_miner_process_smoke=passed
step_no_background_process_smoke=passed
step_no_upload_static_audit=passed
step_portability_contract_audit=passed
step_ai_safety_contract_audit=passed
step_feature_export_smoke=passed
step_system_critical_policy_smoke=passed
step_usb_10k_smoke=passed
step_usb_detection_smoke=passed
step_quarantine_roundtrip_smoke=passed
step_quarantine_confirmation_smoke=passed
step_package_release=passed
step_sign_release_artifact=passed
step_verify_checksums=passed
step_verify_release_signatures=passed
step_release_artifact_smoke=passed
background_process_check=passed
no_upload_static_audit=passed
portability_contract_audit=passed
ai_safety_contract_audit=passed
feature_export_smoke=passed
system_critical_policy_smoke=passed
report_redaction_smoke=passed
miner_process_smoke=passed
usb_detection_smoke=passed
quarantine_confirmation_smoke=passed
quick_duration_ms=100
quick_memory_kb=1000
full_budget_duration_ms=0
progress_latency_ms=100
usb10k_duration_ms=1000
release_binary_size_bytes=1024
release_binary_max_bytes=52428800
artifact_dir_size_bytes=2048
artifact_dir_max_bytes=104857600
status=passed
SUMMARY
  cat >"$dir/platform.txt" <<'PLATFORM'
date_utc=2026-06-07T00:00:00Z
uname_s=Darwin
PLATFORM
  write_local_platform_reports "$dir"
  write_local_platform_logs "$dir"
  printf 'status=passed\n' >"$dir/quarantine-roundtrip/summary.txt"
}

make_physical_usb_evidence() {
  local dir="$1"
  local removable_media="$2"
  local mode="$3"
  local duration_ms="$4"
  local scanned_files="$5"

  mkdir -p "$dir/reports" "$dir/logs"
  cat >"$dir/summary.txt" <<SUMMARY
drive=/tmp/fake-usb
evidence_dir=/tmp/fake-evidence
max_ms=90000
min_files=10000
file_count=10000
require_removable=1
removable_media=$removable_media
removable_media_detector=macos_diskutil
removable_media_detail=Removable Media
duration_ms=$duration_ms
scanned_files=$scanned_files
status=passed
SUMMARY

  cat >"$dir/platform.txt" <<'PLATFORM'
date_utc=2026-06-07T00:00:00Z
uname_s=Darwin
PLATFORM

  cat >"$dir/reports/physical-usb.json" <<JSON
{"schema_version":"1","app_version":"fixture","mode":"$mode","started_at":"2026-06-07T00:00:00Z","finished_at":"2026-06-07T00:00:01Z","duration_ms":$duration_ms,"memory_peak_kb":1024,"scanned_files":$scanned_files,"scanned_persistence_entries":0,"findings":[],"warnings":[]}
JSON
  cp "$dir/reports/physical-usb.json" "$dir/logs/physical-usb.stdout"
  printf '<!doctype html><html><head><style>body{font-family:sans-serif}</style></head><body>ok</body></html>\n' \
    >"$dir/reports/physical-usb.html"
  printf 'panicscan: starting Usb scan\n' >"$dir/logs/physical-usb.stderr"
}

make_physical_usb_evidence "$physical" "" "Usb" "1000" "10000"

make_local_platform_evidence "$missing_local_log"
rm "$missing_local_log/logs/full_budget_smoke.stderr"

missing_local_log_output="$root/missing-local-log.out"
if scripts/mvp_acceptance_gate.sh \
  "$missing_local_log" \
  "$root/missing-ci" \
  "$physical" \
  "$root/missing-release" \
  >"$missing_local_log_output" 2>&1; then
  echo "expected missing local platform log evidence fixture to fail" >&2
  exit 1
fi

if ! grep -q 'full_budget_smoke.stderr' "$missing_local_log_output"; then
  echo "expected missing local full-budget log failure" >&2
  sed -n '1,160p' "$missing_local_log_output" >&2
  exit 1
fi

make_local_platform_evidence "$missing_local_signature_step"
awk '$0 != "step_verify_release_signatures=passed"' \
  "$missing_local_signature_step/summary.txt" \
  >"$missing_local_signature_step/summary.txt.tmp"
mv "$missing_local_signature_step/summary.txt.tmp" "$missing_local_signature_step/summary.txt"

missing_local_signature_output="$root/missing-local-signature.out"
if scripts/mvp_acceptance_gate.sh \
  "$missing_local_signature_step" \
  "$root/missing-ci" \
  "$physical" \
  "$root/missing-release" \
  >"$missing_local_signature_output" 2>&1; then
  echo "expected missing local signature verification step fixture to fail" >&2
  exit 1
fi

if ! grep -q 'step_verify_release_signatures=passed' "$missing_local_signature_output"; then
  echo "expected missing local signature verification step failure" >&2
  sed -n '1,160p' "$missing_local_signature_output" >&2
  exit 1
fi

make_local_platform_evidence "$oversize_local_binary"
awk '
  /^release_binary_size_bytes=/ { print "release_binary_size_bytes=999999999"; next }
  { print }
' "$oversize_local_binary/summary.txt" >"$oversize_local_binary/summary.txt.tmp"
mv "$oversize_local_binary/summary.txt.tmp" "$oversize_local_binary/summary.txt"

oversize_local_output="$root/oversize-local-binary.out"
if scripts/mvp_acceptance_gate.sh \
  "$oversize_local_binary" \
  "$root/missing-ci" \
  "$physical" \
  "$root/missing-release" \
  >"$oversize_local_output" 2>&1; then
  echo "expected oversize local binary fixture to fail" >&2
  exit 1
fi

if ! grep -q 'release_binary_size_bytes' "$oversize_local_output"; then
  echo "expected local binary size budget failure" >&2
  sed -n '1,160p' "$oversize_local_output" >&2
  exit 1
fi

make_physical_usb_evidence "$bad_physical_report" "passed" "Quick" "1000" "10000"

bad_physical_output="$root/bad-physical-report.out"
if scripts/mvp_acceptance_gate.sh \
  /tmp/panicscan-platform-evidence-Darwin \
  "$root/missing-ci" \
  "$bad_physical_report" \
  "$root/missing-release" \
  >"$bad_physical_output" 2>&1; then
  echo "expected bad physical USB report fixture to fail" >&2
  exit 1
fi

if ! grep -q 'physical USB report mode' "$bad_physical_output"; then
  echo "expected physical USB report mode failure" >&2
  sed -n '1,160p' "$bad_physical_output" >&2
  exit 1
fi

make_physical_usb_evidence "$bad_physical_detector" "passed" "Usb" "1000" "10000"
awk '$0 !~ /^removable_media_detector=/' \
  "$bad_physical_detector/summary.txt" \
  >"$bad_physical_detector/summary.txt.tmp"
mv "$bad_physical_detector/summary.txt.tmp" "$bad_physical_detector/summary.txt"

bad_physical_detector_output="$root/bad-physical-detector.out"
if scripts/mvp_acceptance_gate.sh \
  /tmp/panicscan-platform-evidence-Darwin \
  "$root/missing-ci" \
  "$bad_physical_detector" \
  "$root/missing-release" \
  >"$bad_physical_detector_output" 2>&1; then
  echo "expected missing physical USB detector fixture to fail" >&2
  exit 1
fi

if ! grep -q 'removable_media_detector' "$bad_physical_detector_output"; then
  echo "expected physical USB detector failure" >&2
  sed -n '1,160p' "$bad_physical_detector_output" >&2
  exit 1
fi

if scripts/mvp_acceptance_gate.sh \
  /tmp/panicscan-platform-evidence-Darwin \
  /tmp/panicscan-ci-audit-fixture \
  "$physical" \
  "$root/missing-release" \
  >"$output" 2>&1; then
  echo "expected MVP gate fixture to fail without removable media proof" >&2
  exit 1
fi

if ! grep -q 'physical USB evidence does not prove removable media' "$output"; then
  echo "expected removable media proof failure in MVP gate output" >&2
  sed -n '1,160p' "$output" >&2
  exit 1
fi

echo "mvp_acceptance_gate_fixture_test=passed"
echo "fixture_root=$root"
