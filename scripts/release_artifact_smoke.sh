#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

artifact_dir="${PANICSCAN_ARTIFACT_DIR:-}"
if [[ -z "$artifact_dir" ]]; then
  artifact_name="${PANICSCAN_ARTIFACT_NAME:?PANICSCAN_ARTIFACT_NAME or PANICSCAN_ARTIFACT_DIR is required}"
  dist_root="${PANICSCAN_DIST_ROOT:-dist}"
  artifact_dir="$dist_root/$artifact_name"
fi

if [[ ! -d "$artifact_dir" ]]; then
  echo "artifact directory not found: $artifact_dir" >&2
  exit 1
fi

checksum_file="$artifact_dir/SHA256SUMS.txt"
if [[ ! -f "$checksum_file" ]]; then
  echo "checksum file not found: $checksum_file" >&2
  exit 1
fi

scripts/verify_checksums.sh "$checksum_file" >/dev/null

bin=""
for candidate in "$artifact_dir/panicscan" "$artifact_dir/panicscan.exe"; do
  if [[ -f "$candidate" ]]; then
    bin="$candidate"
    break
  fi
done

if [[ -z "$bin" ]]; then
  echo "artifact binary not found in $artifact_dir" >&2
  exit 1
fi

if [[ ! -x "$bin" ]]; then
  chmod +x "$bin" 2>/dev/null || true
fi

smoke_root="${PANICSCAN_ARTIFACT_SMOKE_ROOT:-$(mktemp -d /tmp/panicscan-artifact-smoke.XXXXXX)}"
quick_json="$smoke_root/quick.json"
quick_html="$smoke_root/quick.html"
quick_stdout="$smoke_root/quick.stdout"
quick_stderr="$smoke_root/quick.stderr"
usb_root="$smoke_root/usb"
usb_json="$smoke_root/usb.json"
usb_html="$smoke_root/usb.html"
usb_stdout="$smoke_root/usb.stdout"
usb_stderr="$smoke_root/usb.stderr"

mkdir -p "$usb_root/extensions/ext-smoke" "$usb_root/links"
printf '[autorun]\nopen=setup.exe\n' >"$usb_root/autorun.inf"
printf '{"permissions":["tabs","webRequest","cookies"]}\n' >"$usb_root/extensions/ext-smoke/manifest.json"
printf 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -EncodedCommand SQBFAFgA\n' >"$usb_root/links/risky.lnk"

"$bin" quick --json "$quick_json" --html "$quick_html" >"$quick_stdout" 2>"$quick_stderr" || {
  code=$?
  echo "quick scan failed with code $code. Stderr:" >&2
  cat "$quick_stderr" >&2
  exit $code
}

"$bin" usb "$usb_root" --json "$usb_json" --html "$usb_html" >"$usb_stdout" 2>"$usb_stderr" || {
  code=$?
  echo "usb scan failed with code $code. Stderr:" >&2
  cat "$usb_stderr" >&2
  exit $code
}

for report in "$quick_json" "$quick_html" "$quick_stdout" "$quick_stderr" "$usb_json" "$usb_html" "$usb_stdout" "$usb_stderr"; do
  if [[ ! -s "$report" ]]; then
    echo "expected non-empty smoke output: $report" >&2
    exit 1
  fi
done

if ! grep -q 'panicscan: starting Quick scan' "$quick_stderr"; then
  echo "expected quick progress message in stderr" >&2
  exit 1
fi

if ! grep -q 'panicscan: starting Usb scan' "$usb_stderr"; then
  echo "expected USB progress message in stderr" >&2
  exit 1
fi

if ! grep -q '"mode": "Quick"' "$quick_json"; then
  echo "expected quick JSON report mode" >&2
  exit 1
fi

if ! grep -q '"mode": "Usb"' "$usb_json"; then
  echo "expected USB JSON report mode" >&2
  exit 1
fi

scripts/validate_report_schema.sh "$quick_json" "$quick_stdout" "$usb_json" "$usb_stdout" >/dev/null
scripts/validate_html_offline.sh "$quick_html" "$usb_html" >/dev/null

quick_duration_ms="$(awk -F': ' '/"duration_ms"/ { gsub(/,/, "", $2); print $2; exit }' "$quick_json")"
quick_memory_kb="$(awk -F': ' '/"memory_peak_kb"/ { gsub(/,/, "", $2); print $2; exit }' "$quick_json")"
usb_duration_ms="$(awk -F': ' '/"duration_ms"/ { gsub(/,/, "", $2); print $2; exit }' "$usb_json")"
usb_findings_count="$(awk -F': ' '/"findings"/ { found=1 } found && /"id"/ { count++ } END { print count + 0 }' "$usb_json")"

if [[ -z "$quick_duration_ms" || -z "$quick_memory_kb" || "$quick_memory_kb" == "null" || -z "$usb_duration_ms" ]]; then
  echo "expected duration and memory fields in smoke reports" >&2
  exit 1
fi

if [[ "$usb_findings_count" -lt 1 ]]; then
  echo "expected synthetic USB smoke to produce at least one finding" >&2
  exit 1
fi

cat <<SUMMARY
artifact_dir=$artifact_dir
binary=$bin
smoke_root=$smoke_root
quick_duration_ms=$quick_duration_ms
quick_memory_kb=$quick_memory_kb
usb_duration_ms=$usb_duration_ms
usb_findings_count=$usb_findings_count
SUMMARY
