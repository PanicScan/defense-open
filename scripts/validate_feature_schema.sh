#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema_path="$repo_root/docs/feature-schema-v1.json"

if [[ "$#" -lt 1 ]]; then
  echo "usage: scripts/validate_feature_schema.sh <features.json> [features.json ...]" >&2
  exit 2
fi

python3 - "$schema_path" "$@" <<'PY'
import json
import pathlib
import sys

schema_path = pathlib.Path(sys.argv[1])
paths = [pathlib.Path(arg) for arg in sys.argv[2:]]

schema = json.loads(schema_path.read_text(encoding="utf-8"))
if schema.get("properties", {}).get("schema_version", {}).get("const") != "panicscan.features.v1":
    raise SystemExit(f"schema {schema_path} does not describe panicscan.features.v1")

required_top = [
    "schema_version",
    "source_report_schema_version",
    "app_version",
    "mode",
    "vector_count",
    "vectors",
]
required_vector = [
    "finding_ref",
    "severity",
    "score",
    "score_band",
    "recommended_action",
    "has_item_path",
    "has_process_id",
    "has_persistence_location",
    "path_class",
    "path_extension",
    "evidence_count",
    "evidence_weight_sum",
    "evidence_kinds",
    "evidence_codes",
]
allowed_top = set(required_top)
allowed_vector = set(required_vector)
allowed_modes = {"Quick", "Full", "Usb"}
allowed_severities = {"Info", "Low", "Medium", "High", "Critical"}
allowed_score_bands = {
    "clean_looking",
    "noteworthy",
    "suspicious",
    "high_risk",
    "likely_malicious",
}
allowed_actions = {
    "Ignore",
    "Review",
    "Quarantine",
    "OfflineSecurityScan",
    "ManualExpertReview",
}
allowed_path_classes = {
    "none",
    "user_downloads",
    "user_desktop",
    "temp",
    "removable_or_mounted",
    "system",
    "other",
}
allowed_evidence_kinds = {
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

def fail(path, field, message):
    raise SystemExit(f"{path}: {field}: {message}")

def require_object(path, value, field):
    if not isinstance(value, dict):
        fail(path, field, "expected object")

def require_string(path, value, field):
    if not isinstance(value, str) or not value:
        fail(path, field, "expected non-empty string")

def require_bool(path, value, field):
    if not isinstance(value, bool):
        fail(path, field, "expected boolean")

def require_int(path, value, field, minimum=0, maximum=None):
    if not isinstance(value, int) or isinstance(value, bool):
        fail(path, field, "expected integer")
    if value < minimum:
        fail(path, field, f"expected >= {minimum}")
    if maximum is not None and value > maximum:
        fail(path, field, f"expected <= {maximum}")

for path in paths:
    report = json.loads(path.read_text(encoding="utf-8"))
    require_object(path, report, "<root>")
    missing = [key for key in required_top if key not in report]
    if missing:
        fail(path, "<root>", f"missing keys: {', '.join(missing)}")
    extra = sorted(set(report) - allowed_top)
    if extra:
        fail(path, "<root>", f"unexpected keys: {', '.join(extra)}")
    if report["schema_version"] != "panicscan.features.v1":
        fail(path, "schema_version", f"expected panicscan.features.v1, got {report['schema_version']!r}")
    if report["source_report_schema_version"] != "1":
        fail(path, "source_report_schema_version", "expected 1")
    require_string(path, report["app_version"], "app_version")
    if report["mode"] not in allowed_modes:
        fail(path, "mode", f"invalid mode {report['mode']!r}")
    require_int(path, report["vector_count"], "vector_count")
    vectors = report["vectors"]
    if not isinstance(vectors, list):
        fail(path, "vectors", "expected array")
    if report["vector_count"] != len(vectors):
        fail(path, "vector_count", f"expected {len(vectors)}, got {report['vector_count']}")
    for index, vector in enumerate(vectors):
        field_prefix = f"vectors[{index}]"
        require_object(path, vector, field_prefix)
        missing = [key for key in required_vector if key not in vector]
        if missing:
            fail(path, field_prefix, f"missing keys: {', '.join(missing)}")
        extra = sorted(set(vector) - allowed_vector)
        if extra:
            fail(path, field_prefix, f"unexpected keys: {', '.join(extra)}")
        require_string(path, vector["finding_ref"], f"{field_prefix}.finding_ref")
        if (
            not vector["finding_ref"].startswith("finding-")
            or len(vector["finding_ref"]) != 14
            or not vector["finding_ref"][8:].isdigit()
        ):
            fail(path, f"{field_prefix}.finding_ref", "expected synthetic finding-000001 style reference")
        if vector["severity"] not in allowed_severities:
            fail(path, f"{field_prefix}.severity", f"invalid severity {vector['severity']!r}")
        require_int(path, vector["score"], f"{field_prefix}.score", maximum=100)
        if vector["score_band"] not in allowed_score_bands:
            fail(path, f"{field_prefix}.score_band", f"invalid score band {vector['score_band']!r}")
        if vector["recommended_action"] not in allowed_actions:
            fail(path, f"{field_prefix}.recommended_action", f"invalid action {vector['recommended_action']!r}")
        for key in ["has_item_path", "has_process_id", "has_persistence_location"]:
            require_bool(path, vector[key], f"{field_prefix}.{key}")
        if vector["path_class"] not in allowed_path_classes:
            fail(path, f"{field_prefix}.path_class", f"invalid path class {vector['path_class']!r}")
        extension = vector["path_extension"]
        if extension is not None and not isinstance(extension, str):
            fail(path, f"{field_prefix}.path_extension", "expected string or null")
        require_int(path, vector["evidence_count"], f"{field_prefix}.evidence_count")
        require_int(path, vector["evidence_weight_sum"], f"{field_prefix}.evidence_weight_sum")
        kinds = vector["evidence_kinds"]
        if not isinstance(kinds, list) or any(kind not in allowed_evidence_kinds for kind in kinds):
            fail(path, f"{field_prefix}.evidence_kinds", "expected known evidence kind strings")
        codes = vector["evidence_codes"]
        if not isinstance(codes, list) or any(not isinstance(code, str) or not code for code in codes):
            fail(path, f"{field_prefix}.evidence_codes", "expected non-empty string array")
    print(f"{path}: feature_schema=panicscan.features.v1 vectors={len(vectors)} status=passed")
PY
