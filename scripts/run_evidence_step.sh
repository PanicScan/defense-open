#!/usr/bin/env bash
set -euo pipefail

name="${1:-}"
if [[ -z "$name" || "$#" -lt 2 ]]; then
  echo "usage: scripts/run_evidence_step.sh <step-name> <command> [args...]" >&2
  exit 2
fi
shift

logs_dir="${PANICSCAN_EVIDENCE_LOG_DIR:?PANICSCAN_EVIDENCE_LOG_DIR is required}"
mkdir -p "$logs_dir"

stdout_path="$logs_dir/$name.stdout"
stderr_path="$logs_dir/$name.stderr"

set +e
"$@" >"$stdout_path" 2>"$stderr_path"
status="$?"
set -e

cat "$stdout_path"
cat "$stderr_path" >&2

exit "$status"
