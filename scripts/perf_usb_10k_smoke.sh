#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

cargo build -p panicscan >/dev/null
bin="$(resolve_panicscan_bin debug)"

root="${PANICSCAN_PERF_ROOT:-$(mktemp -d /tmp/panicscan-usb10k.XXXXXX)}"
json_path="${PANICSCAN_PERF_JSON:-/tmp/panicscan-usb10k.json}"
html_path="${PANICSCAN_PERF_HTML:-/tmp/panicscan-usb10k.html}"
stdout_path="${PANICSCAN_PERF_STDOUT:-/tmp/panicscan-usb10k.stdout}"
stderr_path="${PANICSCAN_PERF_STDERR:-/tmp/panicscan-usb10k.stderr}"
max_ms="${PANICSCAN_PERF_MAX_MS:-90000}"

mkdir -p "$root/docs" "$root/scripts" "$root/extensions" "$root/links"

i=1
while [[ "$i" -le 9600 ]]; do
  printf 'benign document %s\n' "$i" >"$root/docs/file-$i.txt"
  i=$((i + 1))
done

i=1
while [[ "$i" -le 250 ]]; do
  printf 'echo benign %s\n' "$i" >"$root/scripts/script-$i.sh"
  i=$((i + 1))
done

i=1
while [[ "$i" -le 100 ]]; do
  extension_dir="$root/extensions/ext-$i"
  mkdir -p "$extension_dir"
  printf '{"permissions":["storage"]}\n' >"$extension_dir/manifest.json"
  i=$((i + 1))
done

i=1
while [[ "$i" -le 49 ]]; do
  printf 'C:\\Windows\\System32\\cmd.exe /c echo benign %s\n' "$i" >"$root/links/shortcut-$i.lnk"
  i=$((i + 1))
done

printf '[autorun]\nopen=setup.exe\n' >"$root/autorun.inf"

file_count="$(find "$root" -type f | wc -l | tr -d ' ')"
if [[ "$file_count" != "10000" ]]; then
  echo "expected 10000 files, created $file_count" >&2
  exit 1
fi

"$bin" usb "$root" --json "$json_path" --html "$html_path" >"$stdout_path" 2>"$stderr_path"

if [[ ! -s "$json_path" || ! -s "$html_path" ]]; then
  echo "expected non-empty JSON and HTML reports" >&2
  exit 1
fi

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null

duration_ms="$(awk -F': ' '/"duration_ms"/ { gsub(/,/, "", $2); print $2; exit }' "$json_path")"
if [[ -z "$duration_ms" ]]; then
  echo "could not read duration_ms from $json_path" >&2
  exit 1
fi

if [[ "$duration_ms" -gt "$max_ms" ]]; then
  echo "USB 10k smoke exceeded ${max_ms}ms: ${duration_ms}ms" >&2
  exit 1
fi

if ! grep -q 'panicscan: starting Usb scan' "$stderr_path"; then
  echo "expected progress message in stderr" >&2
  exit 1
fi

cat <<SUMMARY
root=$root
files=$file_count
duration_ms=$duration_ms
json=$json_path
html=$html_path
stdout=$stdout_path
stderr=$stderr_path
SUMMARY
