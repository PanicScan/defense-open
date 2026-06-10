#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

schema_path="${PANICSCAN_REPORT_SCHEMA:-docs/report-schema-v1.json}"

if [[ "$#" -lt 1 ]]; then
  echo "usage: scripts/validate_report_schema.sh <report.json> [report.json ...]" >&2
  exit 2
fi

if [[ ! -f "$schema_path" ]]; then
  echo "schema file not found: $schema_path" >&2
  exit 1
fi

python3 - "$schema_path" "$@" <<'PY'
import json
import sys
from pathlib import Path

schema_path = Path(sys.argv[1])
report_paths = [Path(path) for path in sys.argv[2:]]

try:
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"invalid schema JSON {schema_path}: {exc}")

if schema.get("properties", {}).get("schema_version", {}).get("const") != "1":
    raise SystemExit(f"schema {schema_path} does not describe schema_version 1")

ROOT_REQUIRED = {
    "schema_version",
    "app_version",
    "mode",
    "started_at",
    "finished_at",
    "duration_ms",
    "memory_peak_kb",
    "scanned_files",
    "scanned_persistence_entries",
    "findings",
    "warnings",
}
FINDING_REQUIRED = {
    "id",
    "severity",
    "score",
    "title",
    "explanation",
    "item_path",
    "process_id",
    "persistence_location",
    "evidences",
    "recommended_action",
}
EVIDENCE_REQUIRED = {"kind", "code", "title", "detail", "weight"}

MODES = {"Quick", "Full", "Usb"}
SEVERITIES = {"Info", "Low", "Medium", "High", "Critical"}
ACTIONS = {
    "Ignore",
    "Review",
    "Quarantine",
    "OfflineSecurityScan",
    "ManualExpertReview",
}
EVIDENCE_KINDS = {
    "Persistence",
    "Execution",
    "File",
    "Script",
    "Shortcut",
    "Browser",
    "Network",
    "Miner",
    "Reputation",
}


def fail(path, location, message):
    raise SystemExit(f"{path}: {location}: {message}")


def require_object(path, location, value):
    if not isinstance(value, dict):
        fail(path, location, "expected object")


def require_string(path, location, value, allow_empty=False):
    if not isinstance(value, str):
        fail(path, location, "expected string")
    if not allow_empty and value == "":
        fail(path, location, "expected non-empty string")


def require_optional_string(path, location, value):
    if value is not None and not isinstance(value, str):
        fail(path, location, "expected string or null")


def require_int(path, location, value, minimum=0, maximum=None):
    if not isinstance(value, int) or isinstance(value, bool):
        fail(path, location, "expected integer")
    if value < minimum:
        fail(path, location, f"expected >= {minimum}")
    if maximum is not None and value > maximum:
        fail(path, location, f"expected <= {maximum}")


def require_optional_int(path, location, value, minimum=0):
    if value is not None:
        require_int(path, location, value, minimum=minimum)


def validate_evidence(path, evidence, index):
    location = f"findings[].evidences[{index}]"
    require_object(path, location, evidence)
    missing = EVIDENCE_REQUIRED - evidence.keys()
    extra = evidence.keys() - EVIDENCE_REQUIRED
    if missing:
        fail(path, location, f"missing fields: {sorted(missing)}")
    if extra:
        fail(path, location, f"unexpected fields: {sorted(extra)}")
    if evidence["kind"] not in EVIDENCE_KINDS:
        fail(path, f"{location}.kind", f"unknown evidence kind: {evidence['kind']}")
    require_string(path, f"{location}.code", evidence["code"])
    require_string(path, f"{location}.title", evidence["title"])
    require_string(path, f"{location}.detail", evidence["detail"], allow_empty=True)
    require_int(path, f"{location}.weight", evidence["weight"], minimum=0, maximum=255)


def validate_finding(path, finding, index):
    location = f"findings[{index}]"
    require_object(path, location, finding)
    missing = FINDING_REQUIRED - finding.keys()
    extra = finding.keys() - FINDING_REQUIRED
    if missing:
        fail(path, location, f"missing fields: {sorted(missing)}")
    if extra:
        fail(path, location, f"unexpected fields: {sorted(extra)}")
    require_string(path, f"{location}.id", finding["id"])
    if finding["severity"] not in SEVERITIES:
        fail(path, f"{location}.severity", f"unknown severity: {finding['severity']}")
    require_int(path, f"{location}.score", finding["score"], minimum=0, maximum=100)
    require_string(path, f"{location}.title", finding["title"])
    require_string(path, f"{location}.explanation", finding["explanation"])
    require_optional_string(path, f"{location}.item_path", finding["item_path"])
    require_optional_int(path, f"{location}.process_id", finding["process_id"], minimum=0)
    require_optional_string(path, f"{location}.persistence_location", finding["persistence_location"])
    if not isinstance(finding["evidences"], list):
        fail(path, f"{location}.evidences", "expected array")
    for evidence_index, evidence in enumerate(finding["evidences"]):
        validate_evidence(path, evidence, evidence_index)
    if finding["recommended_action"] not in ACTIONS:
        fail(path, f"{location}.recommended_action", f"unknown action: {finding['recommended_action']}")


def validate_report(path):
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(path, "$", f"invalid report JSON: {exc}")

    require_object(path, "$", report)
    missing = ROOT_REQUIRED - report.keys()
    extra = report.keys() - ROOT_REQUIRED
    if missing:
        fail(path, "$", f"missing fields: {sorted(missing)}")
    if extra:
        fail(path, "$", f"unexpected fields: {sorted(extra)}")
    if report["schema_version"] != "1":
        fail(path, "schema_version", f"expected 1, got {report['schema_version']}")
    require_string(path, "app_version", report["app_version"])
    if report["mode"] not in MODES:
        fail(path, "mode", f"unknown mode: {report['mode']}")
    require_string(path, "started_at", report["started_at"])
    require_string(path, "finished_at", report["finished_at"])
    require_int(path, "duration_ms", report["duration_ms"])
    require_optional_int(path, "memory_peak_kb", report["memory_peak_kb"])
    require_int(path, "scanned_files", report["scanned_files"])
    require_int(path, "scanned_persistence_entries", report["scanned_persistence_entries"])
    if not isinstance(report["findings"], list):
        fail(path, "findings", "expected array")
    for index, finding in enumerate(report["findings"]):
        validate_finding(path, finding, index)
    if not isinstance(report["warnings"], list):
        fail(path, "warnings", "expected array")
    for index, warning in enumerate(report["warnings"]):
        require_string(path, f"warnings[{index}]", warning, allow_empty=True)
    print(f"{path}: schema_version=1 findings={len(report['findings'])} status=passed")


for report_path in report_paths:
    validate_report(report_path)
PY
