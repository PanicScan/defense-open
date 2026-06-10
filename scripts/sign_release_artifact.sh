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

required="${PANICSCAN_SIGNING_REQUIRED:-0}"

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

write_artifact_checksums() {
  local checksum_file="$artifact_dir/SHA256SUMS.txt"
  : >"$checksum_file"

  local path
  for path in "$artifact_dir"/panicscan "$artifact_dir"/panicscan.exe "$artifact_dir"/*.sigstore.json "$artifact_dir"/*.zip; do
    if [[ -f "$path" ]]; then
      printf '%s  %s\n' "$(sha256_file "$path")" "$(basename "$path")" >>"$checksum_file"
    fi
  done
}

skip_or_fail() {
  local reason="$1"
  if [[ "$required" == "1" || "$required" == "true" ]]; then
    echo "signing required but unavailable: $reason" >&2
    exit 1
  fi
  echo "signing_skipped=$reason"
  exit 0
}

if [[ ! -d "$artifact_dir" ]]; then
  echo "artifact directory not found: $artifact_dir" >&2
  exit 1
fi

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

case "$(uname -s)" in
  Darwin)
    identity="${PANICSCAN_MACOS_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
      skip_or_fail "PANICSCAN_MACOS_SIGN_IDENTITY is not set"
    fi
    if [[ -n "${PANICSCAN_MACOS_CERTIFICATE_P12_BASE64:-}" ]]; then
      if [[ -z "${PANICSCAN_MACOS_CERTIFICATE_PASSWORD:-}" ]]; then
        skip_or_fail "PANICSCAN_MACOS_CERTIFICATE_PASSWORD is required when PANICSCAN_MACOS_CERTIFICATE_P12_BASE64 is set"
      fi
      keychain_dir="${RUNNER_TEMP:-/tmp}"
      keychain_path="$keychain_dir/panicscan-signing.keychain-db"
      keychain_password="$(uuidgen)"
      cert_path="$keychain_dir/panicscan-developer-id.p12"
      printf '%s' "$PANICSCAN_MACOS_CERTIFICATE_P12_BASE64" | base64 --decode >"$cert_path"
      security create-keychain -p "$keychain_password" "$keychain_path"
      trap 'security delete-keychain "$keychain_path" >/dev/null 2>&1 || true; rm -f "$cert_path"' EXIT
      security set-keychain-settings -lut 21600 "$keychain_path"
      security unlock-keychain -p "$keychain_password" "$keychain_path"
      security import "$cert_path" -k "$keychain_path" -P "$PANICSCAN_MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
      security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path"
      security list-keychains -d user -s "$keychain_path"
    fi
    codesign --force --options runtime --timestamp --sign "$identity" "$bin"
    codesign --verify --strict --verbose=2 "$bin"

    if [[ "${PANICSCAN_MACOS_NOTARIZE:-0}" == "1" || "${PANICSCAN_MACOS_NOTARIZE:-0}" == "true" ]]; then
      apple_id="${PANICSCAN_APPLE_ID:-}"
      team_id="${PANICSCAN_APPLE_TEAM_ID:-}"
      password="${PANICSCAN_APPLE_APP_PASSWORD:-}"
      if [[ -z "$apple_id" || -z "$team_id" || -z "$password" ]]; then
        if [[ "$required" == "1" || "$required" == "true" ]]; then
          echo "signing required but unavailable: PANICSCAN_APPLE_ID, PANICSCAN_APPLE_TEAM_ID, and PANICSCAN_APPLE_APP_PASSWORD are required for notarization" >&2
          exit 1
        fi
        echo "notarization_skipped=PANICSCAN_APPLE_ID, PANICSCAN_APPLE_TEAM_ID, and PANICSCAN_APPLE_APP_PASSWORD are required for notarization"
      else
        notarization_zip="$artifact_dir/panicscan-macos-notarization.zip"
        ditto -c -k --keepParent "$bin" "$notarization_zip"
        xcrun notarytool submit "$notarization_zip" \
          --apple-id "$apple_id" \
          --team-id "$team_id" \
          --password "$password" \
          --wait
        echo "notarization_zip=$notarization_zip"
      fi
    fi

    write_artifact_checksums
    echo "signed_platform=macos"
    echo "signed_binary=$bin"
    ;;
  Linux)
    if ! command -v cosign >/dev/null 2>&1; then
      skip_or_fail "cosign is not installed"
    fi
    bundle_path="$bin.sigstore.json"
    cosign sign-blob --yes --bundle "$bundle_path" "$bin"
    write_artifact_checksums
    echo "signed_platform=linux"
    echo "signed_binary=$bin"
    echo "sigstore_bundle=$bundle_path"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    if ! command -v powershell.exe >/dev/null 2>&1; then
      skip_or_fail "powershell.exe is not available"
    fi
    windows_sign_output="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/windows_sign.ps1)"
    printf '%s\n' "$windows_sign_output"
    if grep -q '^signing_skipped=' <<<"$windows_sign_output"; then
      exit 0
    fi
    write_artifact_checksums
    echo "signed_platform=windows"
    echo "signed_binary=$bin"
    ;;
  *)
    skip_or_fail "unsupported signing platform: $(uname -s)"
    ;;
esac
