#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

evidence_root="${1:-${PANICSCAN_CI_EVIDENCE_ROOT:-platform-evidence}}"

if [[ ! -d "$evidence_root" ]]; then
  echo "CI evidence root not found: $evidence_root" >&2
  exit 1
fi

python3 - "$evidence_root" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

expected_artifacts = {
    "panicscan-linux-x64-ci-smoke": "linux",
    "panicscan-macos-ci-smoke": "macos",
    "panicscan-windows-x64-ci-smoke": "windows",
}

expected_platform_text = {
    "panicscan-linux-x64-ci-smoke": ["uname_s=Linux"],
    "panicscan-macos-ci-smoke": ["uname_s=Darwin"],
    "panicscan-windows-x64-ci-smoke": [
        "MINGW",
        "MSYS",
        "CYGWIN",
        "Microsoft Windows",
        "Windows",
    ],
}

required_summary_pairs = {
    "step_build_release": "passed",
    "step_quick_scan": "passed",
    "step_validate_quick_schema": "passed",
    "step_validate_quick_html_offline": "passed",
    "step_report_redaction_smoke": "passed",
    "step_progress_latency_smoke": "passed",
    "step_quick_memory_smoke": "passed",
    "step_full_budget_smoke": "passed",
    "step_miner_process_smoke": "passed",
    "step_no_background_process_smoke": "passed",
    "step_no_upload_static_audit": "passed",
    "step_portability_contract_audit": "passed",
    "step_ai_safety_contract_audit": "passed",
    "step_feature_export_smoke": "passed",
    "step_system_critical_policy_smoke": "passed",
    "step_usb_10k_smoke": "passed",
    "step_usb_detection_smoke": "passed",
    "step_quarantine_roundtrip_smoke": "passed",
    "step_quarantine_confirmation_smoke": "passed",
    "step_package_release": "passed",
    "step_sign_release_artifact": "passed",
    "step_verify_checksums": "passed",
    "step_verify_release_signatures": "passed",
    "step_release_artifact_smoke": "passed",
    "background_process_check": "passed",
    "no_upload_static_audit": "passed",
    "portability_contract_audit": "passed",
    "ai_safety_contract_audit": "passed",
    "feature_export_smoke": "passed",
    "system_critical_policy_smoke": "passed",
    "report_redaction_smoke": "passed",
    "miner_process_smoke": "passed",
    "usb_detection_smoke": "passed",
    "quarantine_confirmation_smoke": "passed",
    "status": "passed",
}

required_report_files = [
    "quick.json",
    "quick.html",
    "quick-memory.json",
    "quick-memory.html",
    "full-budget.json",
    "full-budget.html",
    "progress-latency.json",
    "progress-latency.html",
    "redaction.json",
    "redaction.html",
    "miner-process.json",
    "miner-process.html",
    "no-background.json",
    "no-background.html",
    "usb10k.json",
    "usb10k.html",
    "usb-detection.json",
    "usb-detection.html",
    "feature-source.json",
    "feature-source.html",
    "feature-export.json",
]

required_artifact_smoke_files = [
    "quick.json",
    "quick.html",
    "usb.json",
    "usb.html",
]

required_step_logs = [
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

required_auxiliary_logs = [
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

required_log_files = [
    f"{step_name}.{stream}"
    for step_name in required_step_logs
    for stream in ["stdout", "stderr"]
] + required_auxiliary_logs


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_summary(path):
    values = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def require_nonempty(path):
    if not path.exists() or path.stat().st_size == 0:
        fail(f"expected non-empty CI evidence file: {path}")


def require_numeric_limit(summary, summary_path, key, maximum=None, minimum=None):
    value = summary.get(key)
    if value is None or not value.isdigit():
        fail(f"{summary_path}: expected numeric {key}, got {value!r}")
    parsed = int(value)
    if maximum is not None and parsed > maximum:
        fail(f"{summary_path}: expected {key}<={maximum}, got {parsed}")
    if minimum is not None and parsed < minimum:
        fail(f"{summary_path}: expected {key}>={minimum}, got {parsed}")
    return parsed


def require_summary_budget(summary, summary_path, value_key, max_key):
    maximum = require_numeric_limit(summary, summary_path, max_key, minimum=1)
    return require_numeric_limit(summary, summary_path, value_key, maximum=maximum, minimum=1)


def require_file(path):
    if not path.is_file():
        fail(f"expected CI evidence log file: {path}")


for artifact, platform in expected_artifacts.items():
    artifact_dir = root / artifact
    if not artifact_dir.is_dir():
        fail(f"missing CI evidence artifact directory for {platform}: {artifact_dir}")

    summary_path = artifact_dir / "summary.txt"
    platform_path = artifact_dir / "platform.txt"
    require_nonempty(summary_path)
    require_nonempty(platform_path)
    summary = read_summary(summary_path)
    platform_text = platform_path.read_text(encoding="utf-8", errors="replace")

    if summary.get("artifact_name") != artifact:
        fail(f"{summary_path}: artifact_name mismatch, expected {artifact}")

    if not any(needle in platform_text for needle in expected_platform_text[artifact]):
        fail(f"{platform_path}: platform metadata does not prove expected runner family")

    for key, expected in required_summary_pairs.items():
        actual = summary.get(key)
        if actual != expected:
            fail(f"{summary_path}: expected {key}={expected}, got {actual!r}")

    for metric in [
        "quick_duration_ms",
        "quick_memory_kb",
        "full_budget_duration_ms",
        "progress_latency_ms",
        "usb10k_duration_ms",
    ]:
        require_numeric_limit(summary, summary_path, metric)

    require_summary_budget(summary, summary_path, "release_binary_size_bytes", "release_binary_max_bytes")
    require_summary_budget(summary, summary_path, "artifact_dir_size_bytes", "artifact_dir_max_bytes")

    reports_dir = artifact_dir / "reports"
    for name in required_report_files:
        require_nonempty(reports_dir / name)

    logs_dir = artifact_dir / "logs"
    for name in required_log_files:
        require_file(logs_dir / name)

    for name in required_artifact_smoke_files:
        require_nonempty(artifact_dir / "artifact-smoke" / name)

    require_nonempty(artifact_dir / "quarantine-roundtrip" / "summary.txt")

    dist_root = artifact_dir / "dist" / artifact
    require_nonempty(dist_root / "SHA256SUMS.txt")

print("ci_artifact_evidence_audit=passed")
print(f"evidence_root={root}")
print(f"artifacts_checked={len(expected_artifacts)}")
print("required_platforms=linux,macos,windows")
PY
