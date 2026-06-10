#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

root="${PANICSCAN_MINER_PROCESS_ROOT:-$(mktemp -d /tmp/panicscan-miner-process.XXXXXX)}"
json_path="${PANICSCAN_MINER_PROCESS_JSON:-$root/miner-process.json}"
html_path="${PANICSCAN_MINER_PROCESS_HTML:-$root/miner-process.html}"
stdout_path="${PANICSCAN_MINER_PROCESS_STDOUT:-$root/miner-process.stdout}"
stderr_path="${PANICSCAN_MINER_PROCESS_STDERR:-$root/miner-process.stderr}"

mkdir -p "$root/bin" \
  "$(dirname "$json_path")" \
  "$(dirname "$html_path")" \
  "$(dirname "$stdout_path")" \
  "$(dirname "$stderr_path")"

sleep_bin="$(command -v sleep)"
if [[ -z "$sleep_bin" ]]; then
  echo "sleep command is required for miner process smoke" >&2
  exit 1
fi

if [[ "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
  miner_bin="$root/bin/xmrig.exe"
  cp "$sleep_bin" "$miner_bin"
  chmod +x "$miner_bin"
else
  miner_bin="$root/bin/xmrig"
  ln -sf "$sleep_bin" "$miner_bin"
fi

"$miner_bin" 45 &
miner_pid="$!"
cleanup() {
  kill "$miner_pid" >/dev/null 2>&1 || true
  wait "$miner_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 0.2

"$bin" quick --json "$json_path" --html "$html_path" >"$stdout_path" 2>"$stderr_path"

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null

python3 - "$json_path" "$stdout_path" "$miner_pid" <<'PY'
import json
import pathlib
import sys

json_path = pathlib.Path(sys.argv[1])
stdout_path = pathlib.Path(sys.argv[2])
miner_pid = int(sys.argv[3])
report = json.loads(json_path.read_text(encoding="utf-8"))
stdout_report = json.loads(stdout_path.read_text(encoding="utf-8"))


def matching_findings(document):
    exact_matches = []
    fallback_matches = []
    for finding in document.get("findings", []):
        codes = {
            evidence.get("code")
            for evidence in finding.get("evidences", [])
        }
        if "miner.process_name" not in codes:
            continue
        if finding.get("process_id") == miner_pid:
            exact_matches.append(finding)
            continue

        evidence_details = [
            str(evidence.get("detail") or "")
            for evidence in finding.get("evidences", [])
        ]
        haystack = " ".join([
            str(finding.get("item_path") or ""),
            *evidence_details,
        ]).lower()
        if "xmrig" in haystack:
            fallback_matches.append(finding)
    return exact_matches or fallback_matches


matches = matching_findings(report)
if not matches:
    raise SystemExit(
        f"expected miner.process_name finding for pid {miner_pid} "
        "or synthetic xmrig executable"
    )

stdout_matches = matching_findings(stdout_report)
if not stdout_matches:
    raise SystemExit(
        f"expected stdout miner.process_name finding for pid {miner_pid} "
        "or synthetic xmrig executable"
    )

print("miner_process_smoke=passed")
print(f"miner_pid={miner_pid}")
print(f"findings_count={len(matches)}")
print(f"json={json_path}")
print(f"stdout={stdout_path}")
PY
