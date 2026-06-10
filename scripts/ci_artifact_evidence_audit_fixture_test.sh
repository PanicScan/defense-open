#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_CI_AUDIT_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-ci-audit-fixture-test.XXXXXX)}"
bad_root="$root/bad"
missing_full_root="$root/missing-full-budget"
missing_log_root="$root/missing-log"
oversize_root="$root/oversize"
good_root="$root/good"

write_required_reports() {
  local dir="$1"
  local name
  for name in \
    quick.json quick.html \
    quick-memory.json quick-memory.html \
    progress-latency.json progress-latency.html \
    redaction.json redaction.html \
    miner-process.json miner-process.html \
    no-background.json no-background.html \
    full-budget.json full-budget.html \
    usb10k.json usb10k.html \
    usb-detection.json usb-detection.html \
    feature-source.json feature-source.html feature-export.json
  do
    printf '{}\n' >"$dir/reports/$name"
  done
}

write_required_logs() {
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
    printf 'fixture log: %s\n' "$name" >"$dir/logs/$name"
  done
}

make_artifact() {
  local base="$1"
  local artifact="$2"
  local platform_text="$3"

  local dir="$base/$artifact"
  mkdir -p "$dir/logs" "$dir/reports" "$dir/artifact-smoke" "$dir/quarantine-roundtrip" "$dir/dist/$artifact"
  cat >"$dir/summary.txt" <<SUMMARY
artifact_name=$artifact
step_build_release=passed
step_quick_scan=passed
step_validate_quick_schema=passed
step_validate_quick_html_offline=passed
step_report_redaction_smoke=passed
step_progress_latency_smoke=passed
step_quick_memory_smoke=passed
step_miner_process_smoke=passed
step_no_background_process_smoke=passed
step_full_budget_smoke=passed
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
progress_latency_ms=50
full_budget_duration_ms=0
release_binary_size_bytes=1024
release_binary_max_bytes=52428800
artifact_dir_size_bytes=2048
artifact_dir_max_bytes=104857600
usb10k_duration_ms=1000
status=passed
SUMMARY
  cat >"$dir/platform.txt" <<PLATFORM
date_utc=2026-06-07T00:00:00Z
$platform_text
PLATFORM
  write_required_reports "$dir"
  write_required_logs "$dir"
  printf '{}\n' >"$dir/artifact-smoke/quick.json"
  printf '<!doctype html><html></html>\n' >"$dir/artifact-smoke/quick.html"
  printf '{}\n' >"$dir/artifact-smoke/usb.json"
  printf '<!doctype html><html></html>\n' >"$dir/artifact-smoke/usb.html"
  printf 'status=passed\n' >"$dir/quarantine-roundtrip/summary.txt"
  printf '0000000000000000000000000000000000000000000000000000000000000000  panicscan\n' \
    >"$dir/dist/$artifact/SHA256SUMS.txt"
}

make_artifact "$bad_root" panicscan-linux-x64-ci-smoke "uname_s=Darwin"
make_artifact "$bad_root" panicscan-macos-ci-smoke "uname_s=Darwin"
make_artifact "$bad_root" panicscan-windows-x64-ci-smoke "uname_s=Darwin"

bad_output="$root/bad.out"
if scripts/ci_artifact_evidence_audit.sh "$bad_root" >"$bad_output" 2>&1; then
  echo "expected wrong-platform CI evidence fixture to fail" >&2
  exit 1
fi

if ! grep -q 'platform metadata does not prove expected runner family' "$bad_output"; then
  echo "expected wrong-platform metadata failure" >&2
  sed -n '1,160p' "$bad_output" >&2
  exit 1
fi

make_artifact "$missing_full_root" panicscan-linux-x64-ci-smoke "uname_s=Linux"
make_artifact "$missing_full_root" panicscan-macos-ci-smoke "uname_s=Darwin"
make_artifact "$missing_full_root" panicscan-windows-x64-ci-smoke "uname_s=MINGW64_NT-10.0"
rm "$missing_full_root/panicscan-linux-x64-ci-smoke/reports/full-budget.html"

missing_full_output="$root/missing-full-budget.out"
if scripts/ci_artifact_evidence_audit.sh "$missing_full_root" >"$missing_full_output" 2>&1; then
  echo "expected missing full-budget CI evidence fixture to fail" >&2
  exit 1
fi

if ! grep -q 'full-budget.html' "$missing_full_output"; then
  echo "expected missing full-budget report failure" >&2
  sed -n '1,160p' "$missing_full_output" >&2
  exit 1
fi

make_artifact "$missing_log_root" panicscan-linux-x64-ci-smoke "uname_s=Linux"
make_artifact "$missing_log_root" panicscan-macos-ci-smoke "uname_s=Darwin"
make_artifact "$missing_log_root" panicscan-windows-x64-ci-smoke "uname_s=MINGW64_NT-10.0"
rm "$missing_log_root/panicscan-linux-x64-ci-smoke/logs/full_budget_smoke.stderr"

missing_log_output="$root/missing-log.out"
if scripts/ci_artifact_evidence_audit.sh "$missing_log_root" >"$missing_log_output" 2>&1; then
  echo "expected missing CI log evidence fixture to fail" >&2
  exit 1
fi

if ! grep -q 'full_budget_smoke.stderr' "$missing_log_output"; then
  echo "expected missing full-budget log failure" >&2
  sed -n '1,160p' "$missing_log_output" >&2
  exit 1
fi

make_artifact "$oversize_root" panicscan-linux-x64-ci-smoke "uname_s=Linux"
make_artifact "$oversize_root" panicscan-macos-ci-smoke "uname_s=Darwin"
make_artifact "$oversize_root" panicscan-windows-x64-ci-smoke "uname_s=MINGW64_NT-10.0"
awk '
  /^release_binary_size_bytes=/ { print "release_binary_size_bytes=999999999"; next }
  { print }
' "$oversize_root/panicscan-linux-x64-ci-smoke/summary.txt" \
  >"$oversize_root/panicscan-linux-x64-ci-smoke/summary.txt.tmp"
mv "$oversize_root/panicscan-linux-x64-ci-smoke/summary.txt.tmp" \
  "$oversize_root/panicscan-linux-x64-ci-smoke/summary.txt"

oversize_output="$root/oversize.out"
if scripts/ci_artifact_evidence_audit.sh "$oversize_root" >"$oversize_output" 2>&1; then
  echo "expected oversize CI evidence fixture to fail" >&2
  exit 1
fi

if ! grep -q 'release_binary_size_bytes' "$oversize_output"; then
  echo "expected CI release binary size budget failure" >&2
  sed -n '1,160p' "$oversize_output" >&2
  exit 1
fi

make_artifact "$good_root" panicscan-linux-x64-ci-smoke "uname_s=Linux"
make_artifact "$good_root" panicscan-macos-ci-smoke "uname_s=Darwin"
make_artifact "$good_root" panicscan-windows-x64-ci-smoke "uname_s=MINGW64_NT-10.0"

good_output="$root/good.out"
scripts/ci_artifact_evidence_audit.sh "$good_root" >"$good_output"

if ! grep -q 'ci_artifact_evidence_audit=passed' "$good_output"; then
  echo "expected good CI evidence fixture to pass" >&2
  sed -n '1,160p' "$good_output" >&2
  exit 1
fi

echo "ci_artifact_evidence_audit_fixture_test=passed"
echo "fixture_root=$root"
