#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

root="${PANICSCAN_BACKGROUND_ROOT:-target/panicscan-background-smoke}"
json_path="${PANICSCAN_BACKGROUND_JSON:-$root/no-background.json}"
html_path="${PANICSCAN_BACKGROUND_HTML:-$root/no-background.html}"
stdout_path="${PANICSCAN_BACKGROUND_STDOUT:-$root/no-background.stdout}"
stderr_path="${PANICSCAN_BACKGROUND_STDERR:-$root/no-background.stderr}"
timeout_seconds="${PANICSCAN_BACKGROUND_TIMEOUT_SECONDS:-60}"

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

export PANICSCAN_BACKGROUND_BIN
PANICSCAN_BACKGROUND_BIN="$(native_path "$bin")"
export PANICSCAN_BACKGROUND_REPO_ROOT
PANICSCAN_BACKGROUND_REPO_ROOT="$(native_path "$repo_root")"
export PANICSCAN_BACKGROUND_JSON_NATIVE
PANICSCAN_BACKGROUND_JSON_NATIVE="$(native_path "$json_path")"
export PANICSCAN_BACKGROUND_HTML_NATIVE
PANICSCAN_BACKGROUND_HTML_NATIVE="$(native_path "$html_path")"
export PANICSCAN_BACKGROUND_STDOUT_NATIVE
PANICSCAN_BACKGROUND_STDOUT_NATIVE="$(native_path "$stdout_path")"
export PANICSCAN_BACKGROUND_STDERR_NATIVE
PANICSCAN_BACKGROUND_STDERR_NATIVE="$(native_path "$stderr_path")"
export PANICSCAN_BACKGROUND_TIMEOUT_SECONDS="$timeout_seconds"

python3 <<'PY'
import csv
import json
import os
import pathlib
import subprocess
import sys
import time


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_timeout():
    value = os.environ["PANICSCAN_BACKGROUND_TIMEOUT_SECONDS"]
    try:
        parsed = float(value)
    except ValueError:
        fail(f"PANICSCAN_BACKGROUND_TIMEOUT_SECONDS must be numeric, got {value!r}")
    if parsed <= 0:
        fail(f"PANICSCAN_BACKGROUND_TIMEOUT_SECONDS must be positive, got {value!r}")
    return parsed


def snapshot_panicscan_processes():
    if os.name == "nt":
        return snapshot_windows_panicscan_processes()
    return snapshot_posix_panicscan_processes()


def snapshot_windows_panicscan_processes():
    try:
        result = subprocess.run(
            ["tasklist.exe", "/FI", "IMAGENAME eq panicscan.exe", "/FO", "CSV", "/NH"],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except FileNotFoundError:
        fail("tasklist.exe is required for Windows process snapshot")
    if result.returncode != 0:
        return {}

    processes = {}
    for row in csv.reader(result.stdout.splitlines()):
        if len(row) < 2:
            continue
        name = row[0].strip()
        if name.upper().startswith("INFO:"):
            continue
        try:
            pid = int(row[1])
        except ValueError:
            continue
        processes[pid] = f"{pid} {name}"
    return processes


def snapshot_posix_panicscan_processes():
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,comm=,args="],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except FileNotFoundError:
        fail("ps is required for POSIX process snapshot")
    except PermissionError as exc:
        fail(f"could not inspect POSIX process table with ps: {exc}")
    if result.returncode != 0:
        return {}

    processes = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        comm = parts[2]
        args = parts[3] if len(parts) > 3 else ""
        haystack = f"{comm} {args}".lower()
        if "panicscan" in haystack:
            processes[pid] = line.strip()
    return processes


bin_path = os.environ["PANICSCAN_BACKGROUND_BIN"]
repo_root = os.environ["PANICSCAN_BACKGROUND_REPO_ROOT"]
json_path = pathlib.Path(os.environ["PANICSCAN_BACKGROUND_JSON_NATIVE"])
html_path = pathlib.Path(os.environ["PANICSCAN_BACKGROUND_HTML_NATIVE"])
stdout_path = pathlib.Path(os.environ["PANICSCAN_BACKGROUND_STDOUT_NATIVE"])
stderr_path = pathlib.Path(os.environ["PANICSCAN_BACKGROUND_STDERR_NATIVE"])
timeout_seconds = read_timeout()

for path in [json_path, html_path, stdout_path, stderr_path]:
    path.parent.mkdir(parents=True, exist_ok=True)

before = snapshot_panicscan_processes()
start = time.monotonic()
with stdout_path.open("w", encoding="utf-8", errors="replace") as stdout_file, stderr_path.open(
    "w", encoding="utf-8", errors="replace"
) as stderr_file:
    proc = subprocess.Popen(
        [bin_path, "quick", "--json", str(json_path), "--html", str(html_path)],
        cwd=repo_root,
        stdout=stdout_file,
        stderr=stderr_file,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    try:
        proc.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
        fail(f"quick scan exceeded timeout {timeout_seconds:.3f}s")

duration_ms = int(round((time.monotonic() - start) * 1000))
if proc.returncode != 0:
    fail(f"quick scan exited with status {proc.returncode}")

time.sleep(0.2)
after = snapshot_panicscan_processes()
remaining = {pid: entry for pid, entry in after.items() if pid not in before}
if remaining:
    details = "; ".join(f"{pid}: {entry}" for pid, entry in sorted(remaining.items()))
    fail(f"panicscan process remained after exit: {details}")

for path in [json_path, html_path, stdout_path]:
    if not path.exists() or path.stat().st_size == 0:
        fail(f"expected non-empty output: {path}")

try:
    report = json.loads(json_path.read_text(encoding="utf-8"))
except Exception as exc:
    fail(f"could not parse JSON report {json_path}: {exc}")

print("background_process_check=passed")
print(f"scan_pid={proc.pid}")
print(f"wall_duration_ms={duration_ms}")
print(f"report_duration_ms={report.get('duration_ms', 'unknown')}")
print("remaining_panicscan_processes=0")
print(f"json={json_path}")
print(f"html={html_path}")
print(f"stdout={stdout_path}")
print(f"stderr={stderr_path}")
PY

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null
