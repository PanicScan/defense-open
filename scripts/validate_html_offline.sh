#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$#" -lt 1 ]]; then
  echo "usage: scripts/validate_html_offline.sh <report.html> [report.html ...]" >&2
  exit 2
fi

python3 - "$@" <<'PY'
import re
import sys
from pathlib import Path

FORBIDDEN_TAGS = {
    "script",
    "iframe",
    "object",
    "embed",
    "link",
    "img",
    "video",
    "audio",
    "source",
}

FORBIDDEN_PATTERNS = [
    (re.compile(r"https?://", re.IGNORECASE), "external URL"),
    (re.compile(r"(?<!:)//[A-Za-z0-9.-]+", re.IGNORECASE), "protocol-relative URL"),
    (re.compile(r"\b(?:src|href)\s*=", re.IGNORECASE), "resource attribute"),
    (re.compile(r"\burl\s*\(", re.IGNORECASE), "CSS url() resource"),
]


def fail(path, message):
    raise SystemExit(f"{path}: {message}")


def validate(path):
    if not path.is_file():
        fail(path, "file not found")
    html = path.read_text(encoding="utf-8")
    if not html.strip():
        fail(path, "empty HTML report")

    lower = html.lower()
    for required in ("<!doctype html", "<html", "<head", "<body", "<style"):
        if required not in lower:
            fail(path, f"missing required offline document marker: {required}")

    for tag in FORBIDDEN_TAGS:
        if re.search(rf"<\s*{tag}\b", html, re.IGNORECASE):
            fail(path, f"forbidden external-capable tag: <{tag}>")

    for pattern, label in FORBIDDEN_PATTERNS:
        if pattern.search(html):
            fail(path, f"forbidden {label}")

    print(f"{path}: offline_html=passed")


for arg in sys.argv[1:]:
    validate(Path(arg))
PY
