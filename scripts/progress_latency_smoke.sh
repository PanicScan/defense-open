#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

root="${PANICSCAN_PROGRESS_ROOT:-target/panicscan-progress-smoke}"
json_path="${PANICSCAN_PROGRESS_JSON:-$root/progress-latency.json}"
html_path="${PANICSCAN_PROGRESS_HTML:-$root/progress-latency.html}"
stdout_path="${PANICSCAN_PROGRESS_STDOUT:-$root/progress-latency.stdout}"
stderr_path="${PANICSCAN_PROGRESS_STDERR:-$root/progress-latency.stderr}"
max_seconds="${PANICSCAN_PROGRESS_MAX_SECONDS:-2}"
total_timeout_seconds="${PANICSCAN_PROGRESS_TOTAL_TIMEOUT_SECONDS:-60}"

mkdir -p \
  "$(dirname "$json_path")" \
  "$(dirname "$html_path")" \
  "$(dirname "$stdout_path")" \
  "$(dirname "$stderr_path")"

native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

export PANICSCAN_PROGRESS_BIN
PANICSCAN_PROGRESS_BIN="$(native_path "$bin")"
export PANICSCAN_PROGRESS_REPO_ROOT
PANICSCAN_PROGRESS_REPO_ROOT="$(native_path "$repo_root")"
export PANICSCAN_PROGRESS_JSON_NATIVE
PANICSCAN_PROGRESS_JSON_NATIVE="$(native_path "$json_path")"
export PANICSCAN_PROGRESS_HTML_NATIVE
PANICSCAN_PROGRESS_HTML_NATIVE="$(native_path "$html_path")"
export PANICSCAN_PROGRESS_STDOUT_NATIVE
PANICSCAN_PROGRESS_STDOUT_NATIVE="$(native_path "$stdout_path")"
export PANICSCAN_PROGRESS_STDERR_NATIVE
PANICSCAN_PROGRESS_STDERR_NATIVE="$(native_path "$stderr_path")"
export PANICSCAN_PROGRESS_MAX_SECONDS="$max_seconds"
export PANICSCAN_PROGRESS_TOTAL_TIMEOUT_SECONDS="$total_timeout_seconds"
# Cap scan at 2 min on CI runners with large Temp dirs (Windows Actions).
export PANICSCAN_SCAN_MAX_MINUTES="${PANICSCAN_SCAN_MAX_MINUTES:-2}"

python3 <<'PY'
import json
import os
import pathlib
import queue
import subprocess
import sys
import threading
import time


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_float(name):
    value = os.environ[name]
    try:
        parsed = float(value)
    except ValueError:
        fail(f"{name} must be numeric, got {value!r}")
    if parsed < 0:
        fail(f"{name} must be non-negative, got {value!r}")
    return parsed


bin_path = os.environ["PANICSCAN_PROGRESS_BIN"]
repo_root = os.environ["PANICSCAN_PROGRESS_REPO_ROOT"]
json_path = pathlib.Path(os.environ["PANICSCAN_PROGRESS_JSON_NATIVE"])
html_path = pathlib.Path(os.environ["PANICSCAN_PROGRESS_HTML_NATIVE"])
stdout_path = pathlib.Path(os.environ["PANICSCAN_PROGRESS_STDOUT_NATIVE"])
stderr_path = pathlib.Path(os.environ["PANICSCAN_PROGRESS_STDERR_NATIVE"])
max_seconds = read_float("PANICSCAN_PROGRESS_MAX_SECONDS")
total_timeout_seconds = read_float("PANICSCAN_PROGRESS_TOTAL_TIMEOUT_SECONDS")
marker = "panicscan: starting Quick scan"

for path in [json_path, html_path, stdout_path, stderr_path]:
    path.parent.mkdir(parents=True, exist_ok=True)

events = queue.Queue()
start = time.monotonic()
stdout_file = stdout_path.open("w", encoding="utf-8", errors="replace")
stderr_file = stderr_path.open("w", encoding="utf-8", errors="replace")
proc = subprocess.Popen(
    [bin_path, "quick", "--json", str(json_path), "--html", str(html_path)],
    cwd=repo_root,
    stdout=stdout_file,
    stderr=subprocess.PIPE,
    text=True,
    encoding="utf-8",
    errors="replace",
    bufsize=1,
)


def reader():
    assert proc.stderr is not None
    for line in proc.stderr:
        seen_at = time.monotonic()
        stderr_file.write(line)
        stderr_file.flush()
        events.put((seen_at, line))


reader_thread = threading.Thread(target=reader, daemon=True)
reader_thread.start()


def stop_process():
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


first_progress_at = None
try:
    while first_progress_at is None:
        try:
            seen_at, line = events.get(timeout=0.02)
            if marker in line:
                first_progress_at = seen_at
                break
        except queue.Empty:
            pass

        elapsed = time.monotonic() - start
        if elapsed > max_seconds:
            stop_process()
            fail(f"first progress exceeded {max_seconds:.3f}s")

        if proc.poll() is not None:
            break

    if first_progress_at is None:
        while not events.empty():
            seen_at, line = events.get_nowait()
            if marker in line:
                first_progress_at = seen_at
                break
    if first_progress_at is None:
        stop_process()
        fail(f"missing first progress marker: {marker}")

    remaining = total_timeout_seconds - (time.monotonic() - start)
    if remaining <= 0:
        stop_process()
        fail(f"quick scan exceeded total timeout {total_timeout_seconds:.3f}s")
    try:
        proc.wait(timeout=remaining)
    except subprocess.TimeoutExpired:
        stop_process()
        fail(f"quick scan exceeded total timeout {total_timeout_seconds:.3f}s")
finally:
    stdout_file.close()
    stderr_file.close()

reader_thread.join(timeout=2)

if proc.returncode != 0:
    fail(f"quick scan exited with status {proc.returncode}")

for path in [json_path, html_path, stdout_path]:
    if not path.exists() or path.stat().st_size == 0:
        fail(f"expected non-empty output: {path}")

latency_ms = int(round((first_progress_at - start) * 1000))
max_ms = int(round(max_seconds * 1000))
if latency_ms > max_ms:
    fail(f"first progress exceeded {max_ms}ms: {latency_ms}ms")

try:
    report = json.loads(json_path.read_text(encoding="utf-8"))
except Exception as exc:
    fail(f"could not parse JSON report {json_path}: {exc}")

print(f"progress_latency_ms={latency_ms}")
print(f"progress_max_ms={max_ms}")
print(f"duration_ms={report.get('duration_ms', 'unknown')}")
print(f"json={json_path}")
print(f"html={html_path}")
print(f"stdout={stdout_path}")
print(f"stderr={stderr_path}")
PY

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null
