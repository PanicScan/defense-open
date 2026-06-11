#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 <<'PY'
import pathlib
import re
import sys


ROOT = pathlib.Path.cwd()

BLOCKED_DEPENDENCIES = {
    "curl",
    "hyper-rustls",
    "isahc",
    "reqwest",
    "surf",
    "ureq",
}

NETWORK_API_PATTERNS = [
    (re.compile(r"\breqwest::"), "reqwest API"),
    (re.compile(r"\bureq::"), "ureq API"),
    (re.compile(r"\bcurl::"), "curl API"),
    (re.compile(r"\bisahc::"), "isahc API"),
    (re.compile(r"\bsurf::"), "surf API"),
]

COMMAND_RE = re.compile(r"(?:std::process::)?Command::new\s*\(\s*\"([^\"]+)\"")
ALLOWED_RUNTIME_COMMANDS = {"schtasks", "systemctl", "launchctl", "powershell", "notify-send", "osascript"}


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read(path):
    return path.read_text(encoding="utf-8", errors="replace")


def audit_lockfile():
    lock_path = ROOT / "Cargo.lock"
    if not lock_path.exists():
        fail("Cargo.lock is required for no-upload dependency audit")

    package_names = []
    for line in read(lock_path).splitlines():
        match = re.match(r'name = "([^"]+)"', line)
        if match:
            package_names.append(match.group(1))

    blocked = sorted(set(package_names) & BLOCKED_DEPENDENCIES)
    if blocked:
        fail(f"blocked network-capable dependency in Cargo.lock: {', '.join(blocked)}")
    return len(package_names)


def audit_manifests():
    manifest_paths = [
        ROOT / "Cargo.toml",
        ROOT / "crates" / "defense-core" / "Cargo.toml",
    ]
    for path in manifest_paths:
        if not path.exists():
            fail(f"missing manifest for no-upload audit: {path}")
        text = read(path)
        for dep in sorted(BLOCKED_DEPENDENCIES):
            pattern = re.compile(rf'(?m)^\s*{re.escape(dep)}\s*=')
            if pattern.search(text):
                fail(f"blocked network-capable dependency in {path}: {dep}")
    return len(manifest_paths)


def runtime_rust_files():
    root = ROOT / "crates"
    if not root.exists():
        fail("crates directory is required for no-upload runtime audit")
    return sorted(path for path in root.rglob("*.rs") if path.is_file())


def audit_runtime_sources():
    files = runtime_rust_files()
    command_count = 0
    for path in files:
        text = read(path)
        for regex, label in NETWORK_API_PATTERNS:
            match = regex.search(text)
            if match:
                line_no = text[: match.start()].count("\n") + 1
                rel = path.relative_to(ROOT)
                fail(f"runtime network/upload API found in {rel}:{line_no}: {label}")

        for match in COMMAND_RE.finditer(text):
            command_count += 1
            command = match.group(1)
            if command not in ALLOWED_RUNTIME_COMMANDS:
                line_no = text[: match.start()].count("\n") + 1
                rel = path.relative_to(ROOT)
                fail(f"runtime process launch not allowlisted in {rel}:{line_no}: {command}")
    return len(files), command_count


package_count = audit_lockfile()
manifest_count = audit_manifests()
source_count, command_count = audit_runtime_sources()

print("no_upload_static_audit=passed")
print(f"runtime_sources_checked={source_count}")
print(f"manifests_checked={manifest_count}")
print(f"cargo_packages_checked={package_count}")
print(f"runtime_process_launches_checked={command_count}")
print("blocked_network_dependencies=0")
print("runtime_network_api_matches=0")
PY
