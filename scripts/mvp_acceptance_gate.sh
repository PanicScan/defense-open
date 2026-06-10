#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/mvp_acceptance_gate.sh [LOCAL_EVIDENCE_DIR] [CI_EVIDENCE_ROOT] [PHYSICAL_USB_EVIDENCE_DIR] [RELEASE_EVIDENCE_ROOT]

Audits evidence that proves the MVP acceptance checklist. This script does not
run scans or download artifacts; it fails closed when real external evidence is
missing.

Environment overrides:
  PANICSCAN_LOCAL_EVIDENCE_DIR         local platform_evidence_smoke output
  PANICSCAN_CI_EVIDENCE_ROOT           github_ci_evidence_fetch output
  PANICSCAN_PHYSICAL_USB_EVIDENCE_DIR  physical_usb_acceptance output
  PANICSCAN_RELEASE_EVIDENCE_ROOT      public release evidence output
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

default_local="/tmp/panicscan-platform-evidence-$(safe_name "$(uname -s)")"
local_evidence="${1:-${PANICSCAN_LOCAL_EVIDENCE_DIR:-$default_local}}"
ci_evidence="${2:-${PANICSCAN_CI_EVIDENCE_ROOT:-}}"
physical_usb_evidence="${3:-${PANICSCAN_PHYSICAL_USB_EVIDENCE_DIR:-}}"
release_evidence="${4:-${PANICSCAN_RELEASE_EVIDENCE_ROOT:-}}"

python3 - "$local_evidence" "$ci_evidence" "$physical_usb_evidence" "$release_evidence" <<'PY'
import json
import pathlib
import subprocess
import sys

local_evidence = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
ci_evidence = pathlib.Path(sys.argv[2]) if sys.argv[2] else None
physical_usb_evidence = pathlib.Path(sys.argv[3]) if sys.argv[3] else None
release_evidence = pathlib.Path(sys.argv[4]) if sys.argv[4] else None

failures = []
passes = []

local_required_step_logs = [
    "build_release",
    "quick_scan",
    "validate_quick_schema",
    "validate_quick_html_offline",
    "report_redaction_smoke",
    "progress_latency_smoke",
    "quick_memory_smoke",
    "full_budget_smoke",
    "miner_process_smoke",
    "no_background_process_smoke",
    "no_upload_static_audit",
    "portability_contract_audit",
    "ai_safety_contract_audit",
    "feature_export_smoke",
    "system_critical_policy_smoke",
    "usb_10k_smoke",
    "usb_detection_smoke",
    "quarantine_roundtrip_smoke",
    "quarantine_confirmation_smoke",
    "package_release",
    "sign_release_artifact",
    "verify_checksums",
    "verify_release_signatures",
    "release_artifact_smoke",
]

local_required_auxiliary_logs = [
    "platform.stderr",
    "redaction.stdout",
    "redaction.stderr",
    "progress-latency.stdout",
    "progress-latency.stderr",
    "quick-memory.stdout",
    "quick-memory.stderr",
    "full-budget.stdout",
    "full-budget.stderr",
    "miner-process.stdout",
    "miner-process.stderr",
    "no-background.stdout",
    "no-background.stderr",
    "feature-export.stdout",
    "feature-export.stderr",
    "feature-scan.stdout",
    "feature-scan.stderr",
    "system-critical-policy.stdout",
    "system-critical-policy.stderr",
    "usb10k.stdout",
    "usb10k.stderr",
    "usb-detection.stdout",
    "usb-detection.stderr",
]

local_required_log_files = [
    f"{step_name}.{stream}"
    for step_name in local_required_step_logs
    for stream in ["stdout", "stderr"]
] + local_required_auxiliary_logs


def record_pass(message):
    passes.append(message)


def record_fail(message):
    failures.append(message)


def read_summary(path):
    values = {}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        record_fail(f"missing summary file: {path}")
        return values
    if path.stat().st_size == 0:
        record_fail(f"empty summary file: {path}")
        return values
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def require_file(path):
    if not path.exists() or path.stat().st_size == 0:
        record_fail(f"expected non-empty evidence file: {path}")
        return False
    return True


def require_log_file(path):
    if not path.is_file():
        record_fail(f"expected evidence log file: {path}")
        return False
    return True


def require_pair(summary, path, key, expected="passed"):
    actual = summary.get(key)
    if actual != expected:
        record_fail(f"{path}: expected {key}={expected}, got {actual!r}")
        return False
    return True


def require_numeric_limit(summary, path, key, maximum=None, minimum=None):
    value = summary.get(key)
    if value is None or not str(value).isdigit():
        record_fail(f"{path}: expected numeric {key}, got {value!r}")
        return None
    parsed = int(value)
    if maximum is not None and parsed > maximum:
        record_fail(f"{path}: expected {key}<={maximum}, got {parsed}")
    if minimum is not None and parsed < minimum:
        record_fail(f"{path}: expected {key}>={minimum}, got {parsed}")
    return parsed


def require_summary_budget(summary, path, value_key, max_key):
    maximum = require_numeric_limit(summary, path, max_key, minimum=1)
    if maximum is None:
        return None
    return require_numeric_limit(summary, path, value_key, maximum=maximum, minimum=1)


def read_json_file(path, label):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        record_fail(f"{path}: invalid {label} JSON: {exc}")
        return None


def run_validator(command, label):
    executable_command = command
    if command and command[0].endswith(".sh"):
        executable_command = ["bash", *command]
    result = subprocess.run(
        executable_command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        record_fail(f"{label} failed: " + (detail[0] if detail else "unknown error"))
        return False
    return True


def audit_local_evidence(root):
    before = len(failures)
    if root is None or not root.is_dir():
        record_fail(f"local platform evidence directory is missing: {root}")
        return
    summary_path = root / "summary.txt"
    platform_path = root / "platform.txt"
    summary = read_summary(summary_path)
    require_file(platform_path)

    for key in [
        "step_build_release",
        "step_quick_scan",
        "step_validate_quick_schema",
        "step_validate_quick_html_offline",
        "step_report_redaction_smoke",
        "step_progress_latency_smoke",
        "step_quick_memory_smoke",
        "step_full_budget_smoke",
        "step_miner_process_smoke",
        "step_no_background_process_smoke",
        "step_no_upload_static_audit",
        "step_portability_contract_audit",
        "step_ai_safety_contract_audit",
        "step_feature_export_smoke",
        "step_system_critical_policy_smoke",
        "step_usb_10k_smoke",
        "step_usb_detection_smoke",
        "step_quarantine_roundtrip_smoke",
        "step_quarantine_confirmation_smoke",
        "step_package_release",
        "step_sign_release_artifact",
        "step_verify_checksums",
        "step_verify_release_signatures",
        "step_release_artifact_smoke",
        "background_process_check",
        "no_upload_static_audit",
        "portability_contract_audit",
        "ai_safety_contract_audit",
        "feature_export_smoke",
        "system_critical_policy_smoke",
        "report_redaction_smoke",
        "miner_process_smoke",
        "usb_detection_smoke",
        "quarantine_confirmation_smoke",
        "status",
    ]:
        require_pair(summary, summary_path, key)

    require_numeric_limit(summary, summary_path, "quick_duration_ms", maximum=30_000)
    require_numeric_limit(summary, summary_path, "quick_memory_kb", maximum=307_200)
    require_numeric_limit(summary, summary_path, "full_budget_duration_ms", maximum=10_000)
    require_numeric_limit(summary, summary_path, "progress_latency_ms", maximum=2_000)
    require_numeric_limit(summary, summary_path, "usb10k_duration_ms", maximum=90_000)
    require_summary_budget(summary, summary_path, "release_binary_size_bytes", "release_binary_max_bytes")
    require_summary_budget(summary, summary_path, "artifact_dir_size_bytes", "artifact_dir_max_bytes")

    for relative in [
        "reports/quick.json",
        "reports/quick.html",
        "reports/quick-memory.json",
        "reports/quick-memory.html",
        "reports/full-budget.json",
        "reports/full-budget.html",
        "reports/usb10k.json",
        "reports/usb10k.html",
        "reports/usb-detection.json",
        "reports/usb-detection.html",
        "reports/feature-source.json",
        "reports/feature-source.html",
        "reports/feature-export.json",
        "quarantine-roundtrip/summary.txt",
    ]:
        require_file(root / relative)

    for name in local_required_log_files:
        require_log_file(root / "logs" / name)

    if len(failures) == before:
        record_pass(f"local platform evidence checked: {root}")


def audit_ci_evidence(root):
    before = len(failures)
    if root is None or not root.is_dir():
        record_fail("real CI evidence root is missing; run scripts/github_ci_evidence_fetch.sh after CI passes")
        return

    run_metadata = root / "github-run.json"
    if require_file(run_metadata):
        try:
            run = json.loads(run_metadata.read_text(encoding="utf-8"))
        except Exception as exc:
            record_fail(f"{run_metadata}: invalid JSON: {exc}")
            run = {}
        if run.get("conclusion") != "success":
            record_fail(f"{run_metadata}: expected conclusion=success, got {run.get('conclusion')!r}")

    result = subprocess.run(
        ["scripts/ci_artifact_evidence_audit.sh", str(root)],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        record_fail("CI artifact evidence audit failed: " + (detail[0] if detail else "unknown error"))
        return

    expected_platform_text = {
        "panicscan-linux-x64-ci-smoke": ["uname_s=Linux"],
        "panicscan-macos-ci-smoke": ["uname_s=Darwin"],
        "panicscan-windows-x64-ci-smoke": ["MINGW", "MSYS", "CYGWIN", "Microsoft Windows", "Windows"],
    }
    for artifact, needles in expected_platform_text.items():
        platform_path = root / artifact / "platform.txt"
        if not require_file(platform_path):
            continue
        text = platform_path.read_text(encoding="utf-8", errors="replace")
        if not any(needle in text for needle in needles):
            record_fail(f"{platform_path}: platform metadata does not prove expected runner family")

    if len(failures) == before:
        record_pass(f"real CI evidence checked: {root}")


def audit_physical_usb(root):
    before = len(failures)
    if root is None or not root.is_dir():
        record_fail("physical USB evidence directory is missing; run scripts/physical_usb_acceptance.sh on a real removable drive")
        return
    summary_path = root / "summary.txt"
    summary = read_summary(summary_path)
    require_file(root / "platform.txt")
    require_pair(summary, summary_path, "status")
    require_removable = summary.get("require_removable")
    if require_removable not in {"1", "true"}:
        record_fail(
            f"{summary_path}: expected require_removable=1 or true, got {require_removable!r}"
        )
    if summary.get("removable_media") != "passed":
        record_fail(
            f"{summary_path}: physical USB evidence does not prove removable media "
            f"(removable_media={summary.get('removable_media')!r})"
        )
    detector = summary.get("removable_media_detector")
    allowed_detectors = {"macos_diskutil", "linux_lsblk", "windows_powershell"}
    if detector not in allowed_detectors:
        record_fail(
            f"{summary_path}: expected removable_media_detector to be one of "
            f"{sorted(allowed_detectors)}, got {detector!r}"
        )
    detail = summary.get("removable_media_detail")
    if not detail:
        record_fail(f"{summary_path}: expected non-empty removable_media_detail")
    elif "not verified" in detail.lower() or "unsupported" in detail.lower():
        record_fail(f"{summary_path}: removable_media_detail does not prove a real removable drive: {detail!r}")

    file_count = require_numeric_limit(summary, summary_path, "file_count", minimum=10_000)
    min_files = require_numeric_limit(summary, summary_path, "min_files", minimum=10_000)
    if file_count is not None and min_files is not None and file_count < min_files:
        record_fail(f"{summary_path}: file_count {file_count} is below min_files {min_files}")
    duration_ms = require_numeric_limit(summary, summary_path, "duration_ms", maximum=90_000)
    scanned_files = require_numeric_limit(summary, summary_path, "scanned_files", minimum=10_000)

    json_path = root / "reports" / "physical-usb.json"
    html_path = root / "reports" / "physical-usb.html"
    stdout_path = root / "logs" / "physical-usb.stdout"
    stderr_path = root / "logs" / "physical-usb.stderr"

    for path in [json_path, html_path, stdout_path, stderr_path]:
        require_file(path)

    run_validator(
        ["scripts/validate_report_schema.sh", str(json_path), str(stdout_path)],
        "physical USB report schema validation",
    )
    run_validator(
        ["scripts/validate_html_offline.sh", str(html_path)],
        "physical USB HTML offline validation",
    )

    report = read_json_file(json_path, "physical USB report")
    if isinstance(report, dict):
        if report.get("mode") != "Usb":
            record_fail(f"{json_path}: physical USB report mode must be Usb, got {report.get('mode')!r}")
        report_duration = report.get("duration_ms")
        if duration_ms is not None and report_duration != duration_ms:
            record_fail(
                f"{json_path}: duration_ms {report_duration!r} does not match "
                f"{summary_path} duration_ms {duration_ms}"
            )
        report_scanned = report.get("scanned_files")
        if scanned_files is not None and report_scanned != scanned_files:
            record_fail(
                f"{json_path}: scanned_files {report_scanned!r} does not match "
                f"{summary_path} scanned_files {scanned_files}"
            )
        if min_files is not None and isinstance(report_scanned, int) and report_scanned < min_files:
            record_fail(f"{json_path}: scanned_files {report_scanned} is below min_files {min_files}")

    if len(failures) == before:
        record_pass(f"physical USB evidence checked: {root}")


def audit_release_signing(root):
    before = len(failures)
    if root is None or not root.is_dir():
        record_fail("public release evidence root is missing; provide release evidence with signing verification logs")
        return

    result = subprocess.run(
        ["scripts/release_evidence_audit.sh", str(root)],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        details = (result.stderr or result.stdout).strip().splitlines()
        record_fail("public release evidence audit failed: " + (details[0] if details else "unknown error"))

    if len(failures) == before:
        record_pass(f"public release signing evidence checked: {root}")


audit_local_evidence(local_evidence)
audit_ci_evidence(ci_evidence)
audit_physical_usb(physical_usb_evidence)
audit_release_signing(release_evidence)

for message in passes:
    print(f"PASS {message}")

if failures:
    for message in failures:
        print(f"FAIL {message}", file=sys.stderr)
    print("mvp_acceptance_gate=failed", file=sys.stderr)
    raise SystemExit(1)

print("mvp_acceptance_gate=passed")
PY
