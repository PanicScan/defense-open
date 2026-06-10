#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

evidence_root="${1:-${PANICSCAN_RELEASE_EVIDENCE_ROOT:-}}"
if [[ -z "$evidence_root" ]]; then
  echo "usage: scripts/release_evidence_audit.sh <release-evidence-root>" >&2
  exit 2
fi

python3 - "$evidence_root" <<'PY'
import pathlib
import sys
import json

root = pathlib.Path(sys.argv[1])
failures = []


def fail(message):
    failures.append(message)


def require_file(path):
    if not path.exists() or path.stat().st_size == 0:
        fail(f"expected non-empty release evidence file: {path}")
        return False
    return True


def read_json(path):
    if not require_file(path):
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception as exc:
        fail(f"{path}: invalid JSON: {exc}")
        return None


def read_summary(path):
    values = {}
    if not require_file(path):
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def require_numeric_limit(summary, summary_path, key, maximum=None, minimum=None):
    value = summary.get(key)
    if value is None or not value.isdigit():
        fail(f"{summary_path}: expected numeric {key}, got {value!r}")
        return None
    parsed = int(value)
    if maximum is not None and parsed > maximum:
        fail(f"{summary_path}: expected {key}<={maximum}, got {parsed}")
    if minimum is not None and parsed < minimum:
        fail(f"{summary_path}: expected {key}>={minimum}, got {parsed}")
    return parsed


def require_summary_budget(summary, summary_path, value_key, max_key):
    maximum = require_numeric_limit(summary, summary_path, max_key, minimum=1)
    if maximum is None:
        return None
    return require_numeric_limit(summary, summary_path, value_key, maximum=maximum, minimum=1)


def find_release_dir(root, artifact):
    for candidate in [
        root / artifact,
        root / f"{artifact}-release-evidence",
        root / f"{artifact}-evidence",
    ]:
        if candidate.is_dir():
            return candidate
    return root / artifact


def find_first_existing(paths):
    for path in paths:
        if path.exists():
            return path
    return paths[0]


def find_release_binary(artifact_root, artifact):
    for candidate in [
        artifact_root / "dist" / artifact / "panicscan.exe",
        artifact_root / "dist" / artifact / "panicscan",
        artifact_root / "panicscan.exe",
        artifact_root / "panicscan",
    ]:
        if candidate.is_file():
            return candidate
    return artifact_root / "dist" / artifact / "panicscan"


def directory_size_bytes(path):
    total = 0
    for child in path.rglob("*"):
        if child.is_file():
            total += child.stat().st_size
    return total


if not root.is_dir():
    fail(f"release evidence root is missing: {root}")
else:
    run_metadata_path = root / "github-run.json"
    run_metadata = read_json(run_metadata_path)
    if isinstance(run_metadata, dict):
        if run_metadata.get("name") != "Release":
            fail(f"{run_metadata_path}: expected name=Release, got {run_metadata.get('name')!r}")
        if run_metadata.get("status") != "completed":
            fail(f"{run_metadata_path}: expected status=completed, got {run_metadata.get('status')!r}")
        if run_metadata.get("conclusion") != "success":
            fail(f"{run_metadata_path}: expected conclusion=success, got {run_metadata.get('conclusion')!r}")

    expected = {
        "panicscan-windows-x64": "windows",
        "panicscan-macos-universal": "macos",
        "panicscan-linux-x64": "linux",
    }
    for artifact, platform in expected.items():
        artifact_root = find_release_dir(root, artifact)
        if not artifact_root.is_dir():
            fail(f"missing public release evidence directory for {platform}: {artifact_root}")
            continue

        summary_path = artifact_root / "summary.txt"
        summary = read_summary(summary_path)
        require_file(artifact_root / "platform.txt")

        for relative in [
            "artifact-smoke/quick.json",
            "artifact-smoke/quick.html",
            "artifact-smoke/usb.json",
            "artifact-smoke/usb.html",
        ]:
            require_file(artifact_root / relative)

        checksum = find_first_existing([
            artifact_root / "dist" / artifact / "SHA256SUMS.txt",
            artifact_root / "SHA256SUMS.txt",
        ])
        require_file(checksum)

        release_binary = find_release_binary(artifact_root, artifact)
        if require_file(release_binary):
            actual_binary_size = release_binary.stat().st_size
            recorded_binary_size = require_summary_budget(
                summary,
                summary_path,
                "release_binary_size_bytes",
                "release_binary_max_bytes",
            )
            if recorded_binary_size is not None and recorded_binary_size != actual_binary_size:
                fail(
                    f"{summary_path}: release_binary_size_bytes={recorded_binary_size} "
                    f"does not match actual {actual_binary_size} for {release_binary}"
                )

        artifact_dist_dir = artifact_root / "dist" / artifact
        if artifact_dist_dir.is_dir():
            actual_artifact_size = directory_size_bytes(artifact_dist_dir)
            recorded_artifact_size = require_summary_budget(
                summary,
                summary_path,
                "artifact_dir_size_bytes",
                "artifact_dir_max_bytes",
            )
            if recorded_artifact_size is not None and recorded_artifact_size != actual_artifact_size:
                fail(
                    f"{summary_path}: artifact_dir_size_bytes={recorded_artifact_size} "
                    f"does not match actual {actual_artifact_size} for {artifact_dist_dir}"
                )
        else:
            fail(f"missing release artifact directory: {artifact_dist_dir}")

        sign_log = find_first_existing([
            artifact_root / "logs" / "sign_release_artifact.stdout",
            artifact_root / "sign_release_artifact.stdout",
            artifact_root / "signing.txt",
        ])
        verify_log = find_first_existing([
            artifact_root / "logs" / "verify_release_signatures.stdout",
            artifact_root / "verify_release_signatures.stdout",
            artifact_root / "signature-verification.txt",
        ])
        sign_text = ""
        verify_text = ""
        if require_file(sign_log):
            sign_text = sign_log.read_text(encoding="utf-8", errors="replace")
        if require_file(verify_log):
            verify_text = verify_log.read_text(encoding="utf-8", errors="replace")

        combined = sign_text + "\n" + verify_text
        blocked_markers = [
            "signing_skipped=",
            "signature_verification_skipped=",
            "Signature=adhoc",
            "TeamIdentifier=not set",
            "notarization_skipped=",
        ]
        for marker in blocked_markers:
            if marker in combined:
                fail(f"{artifact_root}: public release evidence contains blocked marker {marker!r}")

        if f"signed_platform={platform}" not in sign_text:
            fail(f"{sign_log}: missing signed_platform={platform}")
        if f"signature_verified_platform={platform}" not in verify_text:
            fail(f"{verify_log}: missing signature_verified_platform={platform}")
        if platform == "macos" and "notarization_zip=" not in sign_text:
            fail(f"{sign_log}: missing macOS notarization evidence")
        if platform == "linux" and "sigstore_bundle=" not in combined:
            fail(f"{artifact_root}: missing Linux Sigstore bundle evidence")

if failures:
    for message in failures:
        print(message, file=sys.stderr)
    raise SystemExit(1)

print("release_evidence_audit=passed")
print(f"evidence_root={root}")
print("platforms_checked=windows,macos,linux")
PY
