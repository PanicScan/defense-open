#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failures=0

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=1
}

require_file() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    fail "workflow file is missing or empty: $path"
    return 1
  fi
}

require_text() {
  local path="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" "$path"; then
    fail "$path: missing $label: $needle"
  fi
}

require_file ".github/workflows/ci.yml" || true
require_file ".github/workflows/release.yml" || true

if [[ -s ".github/workflows/ci.yml" ]]; then
  ci=".github/workflows/ci.yml"
  require_text "$ci" "name: CI" "workflow name"
  require_text "$ci" "pull_request:" "pull request trigger"
  require_text "$ci" "branches: [main]" "main push trigger"
  require_text "$ci" "permissions:" "explicit permissions"
  require_text "$ci" "contents: read" "least-privilege contents permission"
  require_text "$ci" "fail-fast: false" "full matrix evidence even when one runner fails"
  require_text "$ci" "panicscan-linux-x64-ci-smoke" "Linux evidence artifact name"
  require_text "$ci" "panicscan-macos-ci-smoke" "macOS evidence artifact name"
  require_text "$ci" "panicscan-windows-x64-ci-smoke" "Windows evidence artifact name"
  require_text "$ci" "cargo fmt --check" "format gate"
  require_text "$ci" "cargo clippy --workspace --all-targets -- -D warnings" "clippy gate"
  require_text "$ci" "cargo test --workspace" "test gate"
  require_text "$ci" "scripts/portability_contract_audit.sh" "portability contract gate"
  require_text "$ci" "scripts/ai_safety_contract_audit.sh" "AI safety contract gate"
  require_text "$ci" "scripts/evidence_next_steps_fixture_test.sh" "evidence next steps fixture"
  require_text "$ci" "scripts/repository_readiness_fixture_test.sh" "repository readiness fixture"
  require_text "$ci" "scripts/github_ci_evidence_fetch_fixture_test.sh" "GitHub CI evidence fetch fixture"
  require_text "$ci" "scripts/github_release_evidence_fetch_fixture_test.sh" "GitHub release evidence fetch fixture"
  require_text "$ci" "scripts/mvp_acceptance_gate_fixture_test.sh" "MVP acceptance gate fixture"
  require_text "$ci" "scripts/feature_export_smoke.sh" "feature export smoke"
  require_text "$ci" "scripts/platform_evidence_smoke.sh" "platform evidence collector"
  require_text "$ci" "actions/upload-artifact@v4" "evidence upload"
  require_text "$ci" "actions/download-artifact@v4" "evidence download"
  require_text "$ci" "scripts/ci_artifact_evidence_audit.sh platform-evidence" "downloaded evidence audit"
fi

if [[ -s ".github/workflows/release.yml" ]]; then
  release=".github/workflows/release.yml"
  require_text "$release" "name: Release" "workflow name"
  require_text "$release" "tags:" "tag trigger"
  require_text "$release" '"v*"' "version tag pattern"
  require_text "$release" "id-token: write" "Sigstore OIDC permission"
  require_text "$release" "fail-fast: false" "full release matrix evidence even when one runner fails"
  require_text "$release" "panicscan-windows-x64" "Windows release artifact"
  require_text "$release" "panicscan-macos-universal" "macOS universal release artifact"
  require_text "$release" "panicscan-linux-x64" "Linux release artifact"
  require_text "$release" "cosign-installer" "Linux Sigstore signing dependency"
  require_text "$release" "rustup target add aarch64-apple-darwin x86_64-apple-darwin" "macOS dual-arch targets"
  require_text "$release" "cargo build --release -p panicscan --target aarch64-apple-darwin" "macOS arm64 build"
  require_text "$release" "cargo build --release -p panicscan --target x86_64-apple-darwin" "macOS x86_64 build"
  require_text "$release" "lipo -create" "macOS universal binary creation"
  require_text "$release" "lipo target/release/panicscan -verify_arch arm64 x86_64" "macOS universal binary verification"
  require_text "$release" "scripts/run_evidence_step.sh sign_release_artifact scripts/sign_release_artifact.sh" "signing evidence capture"
  require_text "$release" "scripts/run_evidence_step.sh verify_checksums scripts/verify_checksums.sh" "checksum evidence capture"
  require_text "$release" "scripts/run_evidence_step.sh verify_release_signatures scripts/verify_release_signatures.sh" "signature verification evidence capture"
  require_text "$release" "scripts/run_evidence_step.sh release_artifact_smoke scripts/release_artifact_smoke.sh" "artifact smoke evidence capture"
  require_text "$release" "release_binary_size_bytes" "release size evidence"
  require_text "$release" "artifact_dir_size_bytes" "artifact directory size evidence"
  require_text "$release" "actions/upload-artifact@v4" "artifact uploads"
  require_text "$release" '${{ matrix.artifact }}-release-evidence' "release evidence artifact upload"
fi

if [[ "$failures" -ne 0 ]]; then
  echo "workflow_contract_audit=failed" >&2
  exit 1
fi

echo "workflow_contract_audit=passed"
