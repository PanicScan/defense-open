#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
audit_root="${PANICSCAN_AI_SAFETY_AUDIT_ROOT:-$repo_root}"

if [[ ! -d "$audit_root" ]]; then
  echo "AI safety audit root not found: $audit_root" >&2
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
        re.compile(r"\bself[-_ ]?propagat(?:e|ing|ion)\b", re.IGNORECASE),
        "self-propagation is outside the defensive product boundary",
    ),
    (
        re.compile(r"\bautonomous\s+(?:third[-_ ]party\s+)?(?:pentest|penetration\s+test|exploit(?:ation)?)\b", re.IGNORECASE),
        "autonomous third-party offensive testing is outside scope",
    ),
    (
        re.compile(r"\bexploit\s+payload\s+(?:sharing|distribution|mirroring|sync)\b", re.IGNORECASE),
        "exploit payload distribution is outside scope",
    ),
    (
        re.compile(r"\bweaponized\s+(?:zero[-_ ]day|exploit|payload)\b", re.IGNORECASE),
        "weaponized vulnerability content must not be distributed",
    ),
    (
        re.compile(r"\braw\s+(?:sample|file)\s+upload\s+by\s+default\b", re.IGNORECASE),
        "raw sample upload by default violates the privacy boundary",
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
    pathlib.Path("scripts/ai_safety_contract_audit.sh"),
    pathlib.Path("scripts/ai_safety_contract_audit_fixture_test.sh"),
}

failures = []
files_checked = 0

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
        for pattern, label in blocked:
            match = pattern.search(text)
            if match:
                failures.append(f"{rel}: blocked AI safety contract violation ({label}): {match.group(0)}")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    raise SystemExit(1)

print("ai_safety_contract_audit=passed")
print(f"files_checked={files_checked}")
print("contract=defensive-ai-ml-p2p-no-self-propagation-no-exploit-payload-distribution")
PY
