#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_RELEASE_AUDIT_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-release-audit-fixture.XXXXXX)}"
bad_root="$root/bad"
missing_smoke_root="$root/missing-smoke"
missing_run_root="$root/missing-run"
failed_run_root="$root/failed-run"
oversize_root="$root/oversize"
good_root="$root/good"

file_size_bytes() {
  wc -c <"$1" | tr -d ' '
}

dir_file_size_bytes() {
  local dir="$1"
  local total=0
  local path
  local size
  while IFS= read -r -d '' path; do
    size="$(file_size_bytes "$path")"
    total="$((total + size))"
  done < <(find "$dir" -type f -print0)
  printf '%s\n' "$total"
}

make_artifact() {
  local base="$1"
  local artifact="$2"
  local platform="$3"
  local sign_extra="$4"
  local verify_extra="$5"

  local dir="$base/$artifact-release-evidence"
  mkdir -p "$dir/logs" "$dir/dist/$artifact" "$dir/artifact-smoke"
  printf 'fixture-binary\n' >"$dir/dist/$artifact/panicscan"
  printf '0000000000000000000000000000000000000000000000000000000000000000  panicscan\n' \
    >"$dir/dist/$artifact/SHA256SUMS.txt"
  release_binary_size_bytes="$(file_size_bytes "$dir/dist/$artifact/panicscan")"
  artifact_dir_size_bytes="$(dir_file_size_bytes "$dir/dist/$artifact")"

  cat >"$dir/summary.txt" <<SUMMARY
artifact_name=$artifact
step_sign_release_artifact=passed
step_verify_checksums=passed
step_verify_release_signatures=passed
step_release_artifact_smoke=passed
release_binary_size_bytes=$release_binary_size_bytes
release_binary_max_bytes=52428800
artifact_dir_size_bytes=$artifact_dir_size_bytes
artifact_dir_max_bytes=104857600
status=passed
SUMMARY
  cat >"$dir/platform.txt" <<PLATFORM
date_utc=2026-06-07T00:00:00Z
runner_os=$platform
PLATFORM
  cat >"$dir/logs/sign_release_artifact.stdout" <<SIGN
signed_platform=$platform
signed_binary=dist/$artifact/panicscan
$sign_extra
SIGN
  cat >"$dir/logs/verify_release_signatures.stdout" <<VERIFY
signature_verified_platform=$platform
signature_verified_binary=dist/$artifact/panicscan
$verify_extra
VERIFY
  printf '{}\n' >"$dir/artifact-smoke/quick.json"
  printf '{}\n' >"$dir/artifact-smoke/usb.json"
  printf '<!doctype html><html></html>\n' >"$dir/artifact-smoke/quick.html"
  printf '<!doctype html><html></html>\n' >"$dir/artifact-smoke/usb.html"
}

write_github_run() {
  local base="$1"
  local conclusion="${2:-success}"
  mkdir -p "$base"
  cat >"$base/github-run.json" <<JSON
{"databaseId":4242,"name":"Release","status":"completed","conclusion":"$conclusion","url":"https://example.test/actions/runs/4242"}
JSON
}

write_github_run "$bad_root"
make_artifact "$bad_root" panicscan-windows-x64 windows "signing_skipped=missing certificate" ""
make_artifact "$bad_root" panicscan-macos-universal macos "notarization_zip=dist/panicscan-macos-universal/panicscan-macos-notarization.zip" ""
make_artifact "$bad_root" panicscan-linux-x64 linux "" "sigstore_bundle=dist/panicscan-linux-x64/panicscan.sigstore.json"

bad_output="$root/bad.out"
if scripts/release_evidence_audit.sh "$bad_root" >"$bad_output" 2>&1; then
  echo "expected bad release evidence fixture to fail" >&2
  exit 1
fi

if ! grep -q "signing_skipped=" "$bad_output"; then
  echo "expected signing_skipped marker failure" >&2
  sed -n '1,160p' "$bad_output" >&2
  exit 1
fi

make_artifact "$missing_smoke_root" panicscan-windows-x64 windows "" ""
make_artifact "$missing_smoke_root" panicscan-macos-universal macos "notarization_zip=dist/panicscan-macos-universal/panicscan-macos-notarization.zip" ""
make_artifact "$missing_smoke_root" panicscan-linux-x64 linux "" "sigstore_bundle=dist/panicscan-linux-x64/panicscan.sigstore.json"
write_github_run "$missing_smoke_root"
rm "$missing_smoke_root/panicscan-linux-x64-release-evidence/artifact-smoke/usb.html"

missing_smoke_output="$root/missing-smoke.out"
if scripts/release_evidence_audit.sh "$missing_smoke_root" >"$missing_smoke_output" 2>&1; then
  echo "expected missing artifact-smoke HTML fixture to fail" >&2
  exit 1
fi

if ! grep -q 'artifact-smoke/usb.html' "$missing_smoke_output"; then
  echo "expected missing artifact-smoke/usb.html failure" >&2
  sed -n '1,160p' "$missing_smoke_output" >&2
  exit 1
fi

make_artifact "$missing_run_root" panicscan-windows-x64 windows "" ""
make_artifact "$missing_run_root" panicscan-macos-universal macos "notarization_zip=dist/panicscan-macos-universal/panicscan-macos-notarization.zip" ""
make_artifact "$missing_run_root" panicscan-linux-x64 linux "" "sigstore_bundle=dist/panicscan-linux-x64/panicscan.sigstore.json"

missing_run_output="$root/missing-run.out"
if scripts/release_evidence_audit.sh "$missing_run_root" >"$missing_run_output" 2>&1; then
  echo "expected missing GitHub Release run metadata fixture to fail" >&2
  exit 1
fi

if ! grep -q 'github-run.json' "$missing_run_output"; then
  echo "expected missing github-run.json failure" >&2
  sed -n '1,160p' "$missing_run_output" >&2
  exit 1
fi

make_artifact "$failed_run_root" panicscan-windows-x64 windows "" ""
make_artifact "$failed_run_root" panicscan-macos-universal macos "notarization_zip=dist/panicscan-macos-universal/panicscan-macos-notarization.zip" ""
make_artifact "$failed_run_root" panicscan-linux-x64 linux "" "sigstore_bundle=dist/panicscan-linux-x64/panicscan.sigstore.json"
write_github_run "$failed_run_root" "failure"

failed_run_output="$root/failed-run.out"
if scripts/release_evidence_audit.sh "$failed_run_root" >"$failed_run_output" 2>&1; then
  echo "expected failed GitHub Release run metadata fixture to fail" >&2
  exit 1
fi

if ! grep -q 'conclusion=success' "$failed_run_output"; then
  echo "expected failed release run conclusion failure" >&2
  sed -n '1,160p' "$failed_run_output" >&2
  exit 1
fi

make_artifact "$oversize_root" panicscan-windows-x64 windows "" ""
make_artifact "$oversize_root" panicscan-macos-universal macos "notarization_zip=dist/panicscan-macos-universal/panicscan-macos-notarization.zip" ""
make_artifact "$oversize_root" panicscan-linux-x64 linux "" "sigstore_bundle=dist/panicscan-linux-x64/panicscan.sigstore.json"
write_github_run "$oversize_root"
awk '
  /^release_binary_size_bytes=/ { print "release_binary_size_bytes=999999999"; next }
  { print }
' "$oversize_root/panicscan-linux-x64-release-evidence/summary.txt" \
  >"$oversize_root/panicscan-linux-x64-release-evidence/summary.txt.tmp"
mv "$oversize_root/panicscan-linux-x64-release-evidence/summary.txt.tmp" \
  "$oversize_root/panicscan-linux-x64-release-evidence/summary.txt"

oversize_output="$root/oversize.out"
if scripts/release_evidence_audit.sh "$oversize_root" >"$oversize_output" 2>&1; then
  echo "expected oversize release evidence fixture to fail" >&2
  exit 1
fi

if ! grep -q 'release_binary_size_bytes' "$oversize_output"; then
  echo "expected release binary size budget failure" >&2
  sed -n '1,160p' "$oversize_output" >&2
  exit 1
fi

make_artifact "$good_root" panicscan-windows-x64 windows "" ""
make_artifact "$good_root" panicscan-macos-universal macos "notarization_zip=dist/panicscan-macos-universal/panicscan-macos-notarization.zip" ""
make_artifact "$good_root" panicscan-linux-x64 linux "" "sigstore_bundle=dist/panicscan-linux-x64/panicscan.sigstore.json"
write_github_run "$good_root"

good_output="$root/good.out"
scripts/release_evidence_audit.sh "$good_root" >"$good_output"

if ! grep -q 'release_evidence_audit=passed' "$good_output"; then
  echo "expected good release evidence fixture to pass" >&2
  sed -n '1,160p' "$good_output" >&2
  exit 1
fi

echo "release_evidence_audit_fixture_test=passed"
echo "fixture_root=$root"
