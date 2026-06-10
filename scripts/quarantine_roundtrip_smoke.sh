#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

root="${PANICSCAN_QUARANTINE_SMOKE_ROOT:-$(mktemp -d /tmp/panicscan-quarantine-smoke.XXXXXX)}"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
work_dir="$root/work-$run_id"
quarantine_dir="$root/quarantine-$run_id"
logs_dir="$root/logs-$run_id"
summary="$root/summary.txt"

mkdir -p "$work_dir" "$quarantine_dir" "$logs_dir"
: >"$summary"

record() {
  printf '%s=%s\n' "$1" "$2" | tee -a "$summary"
}

checksum_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print $1 }'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$path" <<'PY'
import hashlib
import sys
from pathlib import Path

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
  else
    echo "sha256sum, shasum, or python3 is required" >&2
    return 1
  fi
}

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

sample="$work_dir/sample.exe"
sample_contents="panicscan quarantine smoke sample $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$sample_contents" >"$sample"
before_sha="$(checksum_file "$sample")"

guard_stdout="$logs_dir/quarantine-guard.stdout"
guard_stderr="$logs_dir/quarantine-guard.stderr"
if "$bin" quarantine file "$sample" \
  --finding-id smoke-finding \
  --quarantine-dir "$quarantine_dir" \
  >"$guard_stdout" 2>"$guard_stderr"; then
  echo "quarantine unexpectedly succeeded without --yes" >&2
  exit 1
fi

if [[ ! -f "$sample" ]]; then
  echo "quarantine guard removed the sample without --yes" >&2
  exit 1
fi

quarantine_stdout="$logs_dir/quarantine.stdout"
quarantine_stderr="$logs_dir/quarantine.stderr"
"$bin" quarantine file "$sample" \
  --finding-id smoke-finding \
  --quarantine-dir "$quarantine_dir" \
  --yes \
  >"$quarantine_stdout" 2>"$quarantine_stderr"

if [[ -f "$sample" ]]; then
  echo "expected original sample to move into quarantine" >&2
  exit 1
fi

metadata_path="$(find "$quarantine_dir" -maxdepth 1 -type f -name '*.json' | head -n 1)"
quarantine_path="$(find "$quarantine_dir" -maxdepth 1 -type f -name '*.quar' | head -n 1)"

if [[ -z "$metadata_path" || ! -s "$metadata_path" ]]; then
  echo "expected non-empty quarantine metadata JSON" >&2
  exit 1
fi

if [[ -z "$quarantine_path" || ! -s "$quarantine_path" ]]; then
  echo "expected non-empty quarantined payload" >&2
  exit 1
fi

python3 - "$metadata_path" "$before_sha" "$sample" "$quarantine_path" <<'PY'
import json
import sys
from pathlib import Path

metadata_path = Path(sys.argv[1])
expected_sha = sys.argv[2]
expected_original = Path(sys.argv[3])
expected_quarantine = Path(sys.argv[4])
metadata = json.loads(metadata_path.read_text(encoding="utf-8"))

required = {"id", "original_path", "quarantine_path", "sha256", "created_at", "finding_id"}
missing = required - metadata.keys()
if missing:
    raise SystemExit(f"metadata missing fields: {sorted(missing)}")
if metadata["sha256"] != expected_sha:
    raise SystemExit("metadata sha256 does not match original")
if Path(metadata["original_path"]) != expected_original:
    raise SystemExit("metadata original_path does not match sample")
if Path(metadata["quarantine_path"]) != expected_quarantine:
    raise SystemExit("metadata quarantine_path does not match quarantined payload")
if metadata["finding_id"] != "smoke-finding":
    raise SystemExit("metadata finding_id mismatch")
PY

restore_guard_stdout="$logs_dir/restore-guard.stdout"
restore_guard_stderr="$logs_dir/restore-guard.stderr"
if "$bin" quarantine restore "$metadata_path" \
  >"$restore_guard_stdout" 2>"$restore_guard_stderr"; then
  echo "restore unexpectedly succeeded without --yes" >&2
  exit 1
fi

if [[ -f "$sample" ]]; then
  echo "restore guard restored the sample without --yes" >&2
  exit 1
fi

restore_stdout="$logs_dir/restore.stdout"
restore_stderr="$logs_dir/restore.stderr"
"$bin" quarantine restore "$metadata_path" --yes >"$restore_stdout" 2>"$restore_stderr"

if [[ ! -f "$sample" ]]; then
  echo "expected restored sample at original path" >&2
  exit 1
fi

after_sha="$(checksum_file "$sample")"
if [[ "$after_sha" != "$before_sha" ]]; then
  echo "restored sample SHA-256 mismatch" >&2
  exit 1
fi

record "root" "$root"
record "binary" "$bin"
record "sample" "$sample"
record "quarantine_dir" "$quarantine_dir"
record "metadata" "$metadata_path"
record "quarantine_payload" "$quarantine_path"
record "sha256" "$before_sha"
record "status" "passed"

cat "$summary"
