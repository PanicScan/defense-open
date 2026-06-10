#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_GITHUB_RELEASE_FETCH_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-github-release-fetch.XXXXXX)}"
fake_bin="$root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

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

make_release_artifact() {
  local base="$1"
  local artifact="$2"
  local platform="$3"
  local binary_name="panicscan"
  local sign_extra=""
  local verify_extra=""

  if [[ "$platform" == "windows" ]]; then
    binary_name="panicscan.exe"
  elif [[ "$platform" == "macos" ]]; then
    sign_extra="notarization_zip=dist/$artifact/panicscan-macos-notarization.zip"
  elif [[ "$platform" == "linux" ]]; then
    verify_extra="sigstore_bundle=dist/$artifact/panicscan.sigstore.json"
  fi

  local dir="$base/$artifact-release-evidence"
  mkdir -p "$dir/logs" "$dir/dist/$artifact" "$dir/artifact-smoke"
  printf 'fixture-binary\n' >"$dir/dist/$artifact/$binary_name"
  printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' "$binary_name" \
    >"$dir/dist/$artifact/SHA256SUMS.txt"

  local release_binary_size_bytes
  local artifact_dir_size_bytes
  release_binary_size_bytes="$(file_size_bytes "$dir/dist/$artifact/$binary_name")"
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
date_utc=2026-06-08T00:00:00Z
runner_os=$platform
PLATFORM
  cat >"$dir/logs/sign_release_artifact.stdout" <<SIGN
signed_platform=$platform
signed_binary=dist/$artifact/$binary_name
$sign_extra
SIGN
  cat >"$dir/logs/verify_release_signatures.stdout" <<VERIFY
signature_verified_platform=$platform
signature_verified_binary=dist/$artifact/$binary_name
$verify_extra
VERIFY
  printf '{}\n' >"$dir/artifact-smoke/quick.json"
  printf '{}\n' >"$dir/artifact-smoke/usb.json"
  printf '<!doctype html><html></html>\n' >"$dir/artifact-smoke/quick.html"
  printf '<!doctype html><html></html>\n' >"$dir/artifact-smoke/usb.html"
}

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  printf '{"nameWithOwner":"example/repo","url":"https://github.com/example/repo","defaultBranchRef":{"name":"main"}}\n'
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
  if [[ "${PANICSCAN_FAKE_RELEASE_NO_SUCCESS:-0}" == "1" ]]; then
    exit 0
  fi
  printf '4242\n'
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "view" ]]; then
  run_id="${3:-}"
  printf '{"databaseId":%s,"name":"Release","status":"completed","conclusion":"success","url":"https://example.test/actions/runs/%s"}\n' "$run_id" "$run_id"
  exit 0
fi

if [[ "${1:-}" == "run" && "${2:-}" == "download" ]]; then
  run_id="${3:-}"
  shift 3
  dir=""
  names=()
  while [[ "$#" -gt 0 ]]; do
    case "${1:-}" in
      --repo)
        shift 2
        ;;
      --dir)
        dir="${2:-}"
        shift 2
        ;;
      --name)
        names+=("${2:-}")
        shift 2
        ;;
      *)
        echo "unexpected fake gh run download argument for run $run_id: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$dir" ]]; then
    echo "fake gh run download expected --dir" >&2
    exit 1
  fi

  expected=(
    panicscan-windows-x64-release-evidence
    panicscan-macos-universal-release-evidence
    panicscan-linux-x64-release-evidence
  )
  for expected_name in "${expected[@]}"; do
    found=0
    for name in "${names[@]}"; do
      if [[ "$name" == "$expected_name" ]]; then
        found=1
      fi
    done
    if [[ "$found" -ne 1 ]]; then
      echo "fake gh run download missing expected artifact name: $expected_name" >&2
      exit 1
    fi
  done

  make_release_artifact "$dir" panicscan-windows-x64 windows
  make_release_artifact "$dir" panicscan-macos-universal macos
  make_release_artifact "$dir" panicscan-linux-x64 linux
  exit 0
fi

echo "unexpected fake gh invocation: $*" >&2
exit 1
SH
chmod +x "$fake_bin/gh"

no_success_output="$root/no-success.out"
if PANICSCAN_FAKE_RELEASE_NO_SUCCESS=1 \
  PATH="$fake_bin:$PATH" \
  scripts/github_release_evidence_fetch.sh example/repo >"$no_success_output" 2>&1; then
  echo "expected release evidence fetch to fail when no successful Release run exists" >&2
  exit 1
fi

if ! grep -q "no successful Release workflow run found" "$no_success_output"; then
  echo "expected no successful release run failure" >&2
  sed -n '1,160p' "$no_success_output" >&2
  exit 1
fi

nonempty_root="$root/nonempty"
mkdir -p "$nonempty_root"
printf 'do-not-overwrite\n' >"$nonempty_root/existing.txt"
nonempty_output="$root/nonempty.out"
if PATH="$fake_bin:$PATH" \
  scripts/github_release_evidence_fetch.sh example/repo 4242 "$nonempty_root" >"$nonempty_output" 2>&1; then
  echo "expected release evidence fetch to reject non-empty evidence root" >&2
  exit 1
fi

if ! grep -q "release evidence root is not empty" "$nonempty_output"; then
  echo "expected non-empty evidence root failure" >&2
  sed -n '1,160p' "$nonempty_output" >&2
  exit 1
fi

good_root="$root/good"
good_output="$root/good.out"
PANICSCAN_RELEASE_EVIDENCE_ROOT="$good_root" \
  PATH="$fake_bin:$PATH" \
  scripts/github_release_evidence_fetch.sh example/repo >"$good_output"

for expected in \
  "release_evidence_audit=passed" \
  "github_release_evidence_fetch=passed" \
  "repo=example/repo" \
  "run_id=4242" \
  "evidence_root=$good_root"
do
  if ! grep -Fq "$expected" "$good_output"; then
    echo "expected successful release evidence fetch output to contain: $expected" >&2
    sed -n '1,220p' "$good_output" >&2
    exit 1
  fi
done

if [[ ! -s "$good_root/github-run.json" ]]; then
  echo "expected downloaded release evidence root to include github-run.json" >&2
  exit 1
fi

echo "github_release_evidence_fetch_fixture_test=passed"
echo "root=$root"
