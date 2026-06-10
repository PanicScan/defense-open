#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

artifact_name="${PANICSCAN_ARTIFACT_NAME:?PANICSCAN_ARTIFACT_NAME is required}"
binary_path="${PANICSCAN_BINARY_PATH:?PANICSCAN_BINARY_PATH is required}"
dist_root="${PANICSCAN_DIST_ROOT:-dist}"

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "sha256sum or shasum is required" >&2
    exit 1
  fi
}

if [[ ! -f "$binary_path" ]]; then
  echo "binary not found: $binary_path" >&2
  exit 1
fi

artifact_dir="$dist_root/$artifact_name"
mkdir -p "$artifact_dir"

binary_name="$(basename "$binary_path")"
output_path="$artifact_dir/$binary_name"
cp "$binary_path" "$output_path"

checksum_file="$artifact_dir/SHA256SUMS.txt"
checksum="$(sha256_file "$output_path")"
printf '%s  %s\n' "$checksum" "$binary_name" >"$checksum_file"

cat <<SUMMARY
artifact=$artifact_name
binary=$output_path
checksum_file=$checksum_file
sha256=$checksum
SUMMARY
