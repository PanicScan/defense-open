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

skip_or_fail() {
  local reason="$1"
  if [[ "$required" == "1" || "$required" == "true" ]]; then
    echo "signature verification required but unavailable: $reason" >&2
    exit 1
  fi
  echo "signature_verification_skipped=$reason"
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
    if ! codesign --verify --strict --verbose=2 "$bin"; then
      skip_or_fail "macOS binary is not signed with a verifiable code signature"
    fi
    display_output="$(codesign --display --verbose=2 "$bin" 2>&1)"
    printf '%s\n' "$display_output"
    if [[ "$required" == "1" || "$required" == "true" ]]; then
      if grep -q 'Signature=adhoc' <<<"$display_output"; then
        echo "signature verification required but macOS binary only has an ad-hoc signature" >&2
        exit 1
      fi
      if grep -q 'TeamIdentifier=not set' <<<"$display_output"; then
        echo "signature verification required but macOS binary has no Developer ID team identifier" >&2
        exit 1
      fi
    fi
    echo "signature_verified_platform=macos"
    echo "signature_verified_binary=$bin"
    ;;
  Linux)
    bundle_path="$bin.sigstore.json"
    if [[ ! -f "$bundle_path" ]]; then
      skip_or_fail "Sigstore bundle not found: $bundle_path"
    fi
    if ! command -v cosign >/dev/null 2>&1; then
      skip_or_fail "cosign is not installed"
    fi
    identity="${PANICSCAN_COSIGN_CERTIFICATE_IDENTITY:-}"
    issuer="${PANICSCAN_COSIGN_CERTIFICATE_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
    if [[ -z "$identity" ]]; then
      skip_or_fail "PANICSCAN_COSIGN_CERTIFICATE_IDENTITY is not set"
    fi
    cosign verify-blob "$bin" \
      --bundle "$bundle_path" \
      --certificate-identity "$identity" \
      --certificate-oidc-issuer "$issuer"
    echo "signature_verified_platform=linux"
    echo "signature_verified_binary=$bin"
    echo "sigstore_bundle=$bundle_path"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    if ! command -v powershell.exe >/dev/null 2>&1; then
      skip_or_fail "powershell.exe is not available"
    fi
    windows_verify_output="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/windows_verify_signature.ps1)"
    printf '%s\n' "$windows_verify_output"
    if grep -q '^signature_verification_skipped=' <<<"$windows_verify_output"; then
      exit 0
    fi
    echo "signature_verified_platform=windows"
    echo "signature_verified_binary=$bin"
    ;;
  *)
    skip_or_fail "unsupported signature verification platform: $(uname -s)"
    ;;
esac
