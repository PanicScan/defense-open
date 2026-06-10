#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

root="${PANICSCAN_CONFIRMATION_ROOT:-$(mktemp -d /tmp/panicscan-confirmation-smoke.XXXXXX)}"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
work_dir="$root/work-$run_id"
quarantine_dir="$root/quarantine-$run_id"
logs_dir="$root/logs-$run_id"

mkdir -p "$work_dir" "$quarantine_dir" "$logs_dir"

sample="$work_dir/sample.exe"
printf 'panicscan quarantine confirmation smoke\n' >"$sample"

guard_stdout="$logs_dir/quarantine-without-yes.stdout"
guard_stderr="$logs_dir/quarantine-without-yes.stderr"
if "$bin" quarantine file "$sample" \
  --finding-id confirmation-smoke \
  --quarantine-dir "$quarantine_dir" \
  >"$guard_stdout" 2>"$guard_stderr"; then
  echo "quarantine unexpectedly succeeded without --yes" >&2
  exit 1
fi

if [[ ! -f "$sample" ]]; then
  echo "quarantine without --yes moved the file" >&2
  exit 1
fi

quarantine_stdout="$logs_dir/quarantine-with-yes.stdout"
quarantine_stderr="$logs_dir/quarantine-with-yes.stderr"
"$bin" quarantine file "$sample" \
  --finding-id confirmation-smoke \
  --quarantine-dir "$quarantine_dir" \
  --yes \
  >"$quarantine_stdout" 2>"$quarantine_stderr"

if [[ -f "$sample" ]]; then
  echo "quarantine with --yes did not move the file" >&2
  exit 1
fi

metadata_path="$(find "$quarantine_dir" -maxdepth 1 -type f -name '*.json' | head -n 1)"
if [[ -z "$metadata_path" || ! -s "$metadata_path" ]]; then
  echo "expected quarantine metadata JSON after --yes" >&2
  exit 1
fi

restore_guard_stdout="$logs_dir/restore-without-yes.stdout"
restore_guard_stderr="$logs_dir/restore-without-yes.stderr"
if "$bin" quarantine restore "$metadata_path" \
  >"$restore_guard_stdout" 2>"$restore_guard_stderr"; then
  echo "restore unexpectedly succeeded without --yes" >&2
  exit 1
fi

if [[ -f "$sample" ]]; then
  echo "restore without --yes restored the file" >&2
  exit 1
fi

restore_stdout="$logs_dir/restore-with-yes.stdout"
restore_stderr="$logs_dir/restore-with-yes.stderr"
"$bin" quarantine restore "$metadata_path" --yes >"$restore_stdout" 2>"$restore_stderr"

if [[ ! -f "$sample" ]]; then
  echo "restore with --yes did not restore the file" >&2
  exit 1
fi

cat <<SUMMARY
quarantine_confirmation_smoke=passed
root=$root
sample=$sample
quarantine_dir=$quarantine_dir
metadata=$metadata_path
SUMMARY
