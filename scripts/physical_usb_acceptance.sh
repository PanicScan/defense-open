#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib/panicscan_binary.sh"

usage() {
  echo "usage: scripts/physical_usb_acceptance.sh <drive-or-mount-path>" >&2
}

drive="${1:-}"
if [[ -z "$drive" ]]; then
  usage
  exit 2
fi

if [[ ! -d "$drive" ]]; then
  echo "drive or mount path not found: $drive" >&2
  exit 1
fi

case "$drive" in
  /|/System|/bin|/sbin|/usr|/var|/private|/Applications|/Users|C:|C:/|C:\\)
    echo "refusing to treat system path as removable media: $drive" >&2
    exit 1
    ;;
esac

safe_drive="$(printf '%s' "$drive" | tr -c 'A-Za-z0-9._-' '_')"
evidence_dir="${PANICSCAN_PHYSICAL_USB_EVIDENCE_DIR:-/tmp/panicscan-physical-usb-$safe_drive}"
reports_dir="$evidence_dir/reports"
logs_dir="$evidence_dir/logs"
summary="$evidence_dir/summary.txt"
max_ms="${PANICSCAN_PHYSICAL_USB_MAX_MS:-90000}"
min_files="${PANICSCAN_PHYSICAL_USB_MIN_FILES:-10000}"
require_removable="${PANICSCAN_PHYSICAL_USB_REQUIRE_REMOVABLE:-1}"

detect_removable_media() {
  local path="$1"
  local system
  system="$(uname -s)"

  case "$system" in
    Darwin)
      if ! command -v diskutil >/dev/null 2>&1; then
        printf 'failed\tdiskutil\tmissing diskutil\n'
        return 0
      fi
      local info
      info="$(diskutil info "$path" 2>/dev/null || true)"
      if grep -Eiq 'Removable Media:[[:space:]]*(Yes|Removable)' <<<"$info"; then
        printf 'passed\tmacos_diskutil\tRemovable Media\n'
      else
        printf 'failed\tmacos_diskutil\tRemovable Media is not Yes/Removable\n'
      fi
      ;;
    Linux)
      if ! command -v findmnt >/dev/null 2>&1 || ! command -v lsblk >/dev/null 2>&1; then
        printf 'failed\tlinux_lsblk\tmissing findmnt or lsblk\n'
        return 0
      fi
      local source device parent lsblk_output
      source="$(findmnt -no SOURCE --target "$path" 2>/dev/null | head -n 1 || true)"
      if [[ -z "$source" ]]; then
        printf 'failed\tlinux_lsblk\tmount source not found\n'
        return 0
      fi
      device="$source"
      if [[ -e "$device" ]]; then
        device="$(readlink -f "$device" 2>/dev/null || printf '%s' "$device")"
      fi
      lsblk_output="$(lsblk -no RM,TRAN "$device" 2>/dev/null || true)"
      parent="$(lsblk -no PKNAME "$device" 2>/dev/null | head -n 1 || true)"
      if [[ -n "$parent" ]]; then
        lsblk_output="$lsblk_output"$'\n'"$(lsblk -no RM,TRAN "/dev/$parent" 2>/dev/null || true)"
      fi
      if awk '($1 == "1" || $2 == "usb") { found = 1 } END { exit found ? 0 : 1 }' <<<"$lsblk_output"; then
        printf 'passed\tlinux_lsblk\tRM=1 or TRAN=usb\n'
      else
        printf 'failed\tlinux_lsblk\tRM=1 or TRAN=usb not found\n'
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if ! command -v powershell.exe >/dev/null 2>&1; then
        printf 'failed\twindows_powershell\tmissing powershell.exe\n'
        return 0
      fi
      local native drive_letter ps_output
      if command -v cygpath >/dev/null 2>&1; then
        native="$(cygpath -w "$path")"
      else
        native="$path"
      fi
      drive_letter="${native:0:1}"
      ps_output="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$ErrorActionPreference='Stop'; \$volume=Get-Volume -DriveLetter '$drive_letter'; \$disk=\$volume | Get-Partition | Get-Disk; if (\$disk.BusType -eq 'USB') { 'passed' } else { 'failed:' + \$disk.BusType }" 2>/dev/null || true)"
      if grep -q '^passed$' <<<"$ps_output"; then
        printf 'passed\twindows_powershell\tBusType=USB\n'
      else
        printf 'failed\twindows_powershell\tBusType is not USB\n'
      fi
      ;;
    *)
      printf 'failed\tunsupported\tunsupported platform %s\n' "$system"
      ;;
  esac
}

mkdir -p "$reports_dir" "$logs_dir"
: >"$summary"

record() {
  printf '%s=%s\n' "$1" "$2" | tee -a "$summary"
}

record "drive" "$drive"
record "evidence_dir" "$evidence_dir"
record "max_ms" "$max_ms"
record "min_files" "$min_files"
record "require_removable" "$require_removable"

{
  printf 'date_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'uname_s=%s\n' "$(uname -s)"
  printf 'uname_m=%s\n' "$(uname -m)"
  printf 'uname_a=%s\n' "$(uname -a)"
  if command -v df >/dev/null 2>&1; then
    df -h "$drive"
  fi
  if command -v diskutil >/dev/null 2>&1; then
    diskutil info "$drive" || true
  fi
  if command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe /c ver
  fi
} >"$evidence_dir/platform.txt" 2>"$logs_dir/platform.stderr" || true

IFS=$'\t' read -r removable_media removable_detector removable_detail < <(detect_removable_media "$drive")
if [[ "$removable_media" != "passed" && "$require_removable" != "1" && "$require_removable" != "true" ]]; then
  removable_media="skipped"
  removable_detail="not verified because PANICSCAN_PHYSICAL_USB_REQUIRE_REMOVABLE=$require_removable"
fi
record "removable_media" "$removable_media"
record "removable_media_detector" "$removable_detector"
record "removable_media_detail" "$removable_detail"
if [[ "$removable_media" != "passed" ]]; then
  echo "physical USB acceptance requires removable media proof: $removable_detail" >&2
  exit 1
fi

cargo build --release -p panicscan >/dev/null
bin="$(resolve_panicscan_bin release)"
record "release_binary" "$bin"

file_count="$(find "$drive" -type f | wc -l | tr -d ' ')"
record "file_count" "$file_count"
if [[ "$file_count" -lt "$min_files" ]]; then
  echo "physical USB acceptance needs at least $min_files files, found $file_count" >&2
  exit 1
fi

json_path="$reports_dir/physical-usb.json"
html_path="$reports_dir/physical-usb.html"
stdout_path="$logs_dir/physical-usb.stdout"
stderr_path="$logs_dir/physical-usb.stderr"

"$bin" usb "$drive" --json "$json_path" --html "$html_path" >"$stdout_path" 2>"$stderr_path"

if [[ ! -s "$json_path" || ! -s "$html_path" ]]; then
  echo "expected non-empty JSON and HTML reports" >&2
  exit 1
fi

if ! grep -q 'panicscan: starting Usb scan' "$stderr_path"; then
  echo "expected USB progress message in stderr" >&2
  exit 1
fi

scripts/validate_report_schema.sh "$json_path" "$stdout_path" >/dev/null
scripts/validate_html_offline.sh "$html_path" >/dev/null

duration_ms="$(awk -F': ' '/"duration_ms"/ { gsub(/,/, "", $2); print $2; exit }' "$json_path")"
scanned_files="$(awk -F': ' '/"scanned_files"/ { gsub(/,/, "", $2); print $2; exit }' "$json_path")"

if [[ -z "$duration_ms" ]]; then
  echo "could not read duration_ms from $json_path" >&2
  exit 1
fi

if [[ "$duration_ms" -gt "$max_ms" ]]; then
  echo "physical USB scan exceeded ${max_ms}ms: ${duration_ms}ms" >&2
  exit 1
fi

record "duration_ms" "$duration_ms"
record "scanned_files" "${scanned_files:-unknown}"
record "json" "$json_path"
record "html" "$html_path"
record "stdout" "$stdout_path"
record "stderr" "$stderr_path"
record "status" "passed"

cat "$summary"
