#!/usr/bin/env bash
set -euo pipefail

checksum_file="${1:?usage: scripts/verify_checksums.sh <SHA256SUMS.txt>}"
checksum_dir="$(cd "$(dirname "$checksum_file")" && pwd)"
checksum_base="$(basename "$checksum_file")"

cd "$checksum_dir"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c "$checksum_base"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 -c "$checksum_base"
else
  echo "sha256sum or shasum is required" >&2
  exit 1
fi
