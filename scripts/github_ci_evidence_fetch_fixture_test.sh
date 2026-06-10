#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_GITHUB_CI_FETCH_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-github-ci-fetch.XXXXXX)}"
fake_bin="$root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

write_required_reports() {
  local dir="$1"
  local name
  for name in \
    quick.json quick.html \
    quick-memory.json quick-memory.html \
    full-budget.json full-budget.html \
    progress-latency.json progress-latency.html \
    redaction.json redaction.html \
    miner-process.json miner-process.html \
    no-background.json no-background.html \
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

make_ci_artifact() {
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
progress_latency_ms=50
usb10k_duration_ms=1000
release_binary_size_bytes=1024
release_binary_max_bytes=52428800
artifact_dir_size_bytes=2048
artifact_dir_max_bytes=104857600
status=passed
SUMMARY
  cat >"$dir/platform.txt" <<PLATFORM
date_utc=2026-06-08T00:00:00Z
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

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  printf '{"nameWithOwner":"example/repo","url":"https://github.com/example/repo","defaultBranchRef":{"name":"main"}}\n'
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
  if [[ "${PANICSCAN_FAKE_CI_NO_SUCCESS:-0}" == "1" ]]; then
    exit 0
  fi
  printf '2424\n'
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "view" ]]; then
  run_id="${3:-}"
  printf '{"databaseId":%s,"name":"CI","status":"completed","conclusion":"success","url":"https://example.test/actions/runs/%s"}\n' "$run_id" "$run_id"
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "download" ]]; then
  run_id="${3:-}"
  shift 3
  dir=""
  names=()
  while [[ "$#" -gt 0 ]]; do
    case "${1:-}" in
      --repo)
        shift 2
        ;;
      --dir)
        dir="${2:-}"
        shift 2
        ;;
      --name)
        names+=("${2:-}")
        shift 2
        ;;
      *)
        echo "unexpected fake gh run download argument for run $run_id: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$dir" ]]; then
    echo "fake gh run download expected --dir" >&2
    exit 1
  fi

  expected=(
    panicscan-linux-x64-ci-smoke
    panicscan-macos-ci-smoke
    panicscan-windows-x64-ci-smoke
  )
  for expected_name in "${expected[@]}"; do
    found=0
    for name in "${names[@]}"; do
      if [[ "$name" == "$expected_name" ]]; then
        found=1
      fi
    done
    if [[ "$found" -ne 1 ]]; then
      echo "fake gh run download missing expected artifact name: $expected_name" >&2
      exit 1
    fi
  done

  make_ci_artifact "$dir" panicscan-linux-x64-ci-smoke "uname_s=Linux"
  make_ci_artifact "$dir" panicscan-macos-ci-smoke "uname_s=Darwin"
  make_ci_artifact "$dir" panicscan-windows-x64-ci-smoke "uname_s=MINGW64_NT-10.0"
  exit 0
fi

echo "unexpected fake gh invocation: $*" >&2
exit 1
SH
chmod +x "$fake_bin/gh"

no_success_output="$root/no-success.out"
if PANICSCAN_FAKE_CI_NO_SUCCESS=1 \
  PATH="$fake_bin:$PATH" \
  scripts/github_ci_evidence_fetch.sh example/repo >"$no_success_output" 2>&1; then
  echo "expected CI evidence fetch to fail when no successful CI run exists" >&2
  exit 1
fi

if ! grep -q "no successful CI workflow run found" "$no_success_output"; then
  echo "expected no successful CI run failure" >&2
  sed -n '1,160p' "$no_success_output" >&2
  exit 1
fi

nonempty_root="$root/nonempty"
mkdir -p "$nonempty_root"
printf 'do-not-overwrite\n' >"$nonempty_root/existing.txt"
nonempty_output="$root/nonempty.out"
if PATH="$fake_bin:$PATH" \
  scripts/github_ci_evidence_fetch.sh example/repo 2424 "$nonempty_root" >"$nonempty_output" 2>&1; then
  echo "expected CI evidence fetch to reject non-empty evidence root" >&2
  exit 1
fi

if ! grep -q "evidence root is not empty" "$nonempty_output"; then
  echo "expected non-empty evidence root failure" >&2
  sed -n '1,160p' "$nonempty_output" >&2
  exit 1
fi

good_root="$root/good"
good_output="$root/good.out"
PANICSCAN_CI_EVIDENCE_ROOT="$good_root" \
  PATH="$fake_bin:$PATH" \
  scripts/github_ci_evidence_fetch.sh example/repo >"$good_output"

for expected in \
  "ci_artifact_evidence_audit=passed" \
  "github_ci_evidence_fetch=passed" \
  "repo=example/repo" \
  "run_id=2424" \
  "evidence_root=$good_root"
do
  if ! grep -Fq "$expected" "$good_output"; then
    echo "expected successful CI evidence fetch output to contain: $expected" >&2
    sed -n '1,220p' "$good_output" >&2
    exit 1
  fi
done

if [[ ! -s "$good_root/github-run.json" ]]; then
  echo "expected downloaded CI evidence root to include github-run.json" >&2
  exit 1
fi

echo "github_ci_evidence_fetch_fixture_test=passed"
echo "root=$root"
