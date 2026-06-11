#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
audit_root="${DEFENSE_PORTABILITY_AUDIT_ROOT:-$repo_root}"

if [[ ! -d "$audit_root" ]]; then
  echo "portability audit root not found: $audit_root" >&2
  exit 1
fi

python3 - "$audit_root" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
scan_roots = [root / "crates", root / "scripts"]

blocked = [
    (
        re.compile(r"target_arch\s*=\s*['\"](?:x86|x86_64|aarch64|arm|arm64)['\"]"),
        "target_arch-specific runtime gate",
    ),
    (
        re.compile(r"\bis_(?:x86|aarch64|arm)_feature_detected!\b"),
        "CPU feature specific runtime path",
    ),
    (
        re.compile(r"\b(?:nvidia-smi|rocm-smi|intel_gpu_top|dxdiag)\b", re.IGNORECASE),
        "GPU/vendor-specific runtime dependency",
    ),
    (
        re.compile(r"\b(?:AVX2|SSE4|NEON)\b"),
        "CPU instruction-set specific runtime assumption",
    ),
]

runtime_only_blocked = [
    (
        re.compile(
            r"\b(?:"
            r"Windows\s+(?:7|8(?:\.1)?|10|11|12)|"
            r"macOS\s+\d+(?:\.\d+){0,2}|"
            r"OS\s+X\s+\d+(?:\.\d+){0,2}|"
            r"Ubuntu\s+\d+(?:\.\d+){0,2}|"
            r"Fedora\s+\d+|"
            r"Debian\s+\d+"
            r")\b",
            re.IGNORECASE,
        ),
        "OS release-version runtime assumption",
    ),
]

platform_adapter_blocked = [
    (
        re.compile(r"\.(?:unwrap|expect)\s*\("),
        "capability-degradation panic-prone Result/Option use in platform adapter",
    ),
    (
        re.compile(r"\b(?:panic|todo|unimplemented)!\s*\("),
        "capability-degradation panic macro in platform adapter",
    ),
]

extensions = {
    ".rs",
    ".sh",
    ".ps1",
    ".py",
    ".toml",
}
ignored_relative_paths = {
    pathlib.Path("scripts/portability_contract_audit.sh"),
    pathlib.Path("scripts/portability_contract_audit_fixture_test.sh"),
}

platform_adapter_roots = (
    pathlib.Path("crates/defense-core/src/collectors"),
    pathlib.Path("crates/defense-core/src/platform"),
)

failures = []
files_checked = 0

def production_text(text):
    match = re.search(r"(?m)^#\[cfg\(test\)\]\s*\n\s*mod\s+tests\s*\{", text)
    if match:
        return text[: match.start()]
    return text

def is_under(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False

for scan_root in scan_roots:
    if not scan_root.exists():
        continue
    for path in scan_root.rglob("*"):
        if not path.is_file() or path.suffix not in extensions:
            continue
        rel = path.relative_to(root)
        if rel in ignored_relative_paths:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        files_checked += 1
        patterns = list(blocked)
        if rel.parts and rel.parts[0] == "crates":
            patterns.extend(runtime_only_blocked)
        if path.suffix == ".rs" and any(is_under(rel, root) for root in platform_adapter_roots):
            text_to_scan = production_text(text)
            patterns.extend(platform_adapter_blocked)
        else:
            text_to_scan = text
        for pattern, label in patterns:
            match = pattern.search(text_to_scan)
            if match:
                failures.append(f"{rel}: blocked portability assumption ({label}): {match.group(0)}")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    raise SystemExit(1)

print("portability_contract_audit=passed")
print(f"files_checked={files_checked}")
print("contract=capability-based-runtime-no-hardcoded-cpu-gpu-os-release-vendor-no-panic-platform-adapters")
PY
