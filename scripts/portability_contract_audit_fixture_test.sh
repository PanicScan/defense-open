#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_PORTABILITY_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-portability-fixture.XXXXXX)}"
bad_root="$root/bad"
version_bad_root="$root/version-bad"
collector_bad_root="$root/collector-bad"
good_root="$root/good"

mkdir -p \
  "$bad_root/crates/panicscan-core/src" \
  "$version_bad_root/crates/panicscan-core/src" \
  "$collector_bad_root/crates/panicscan-core/src/collectors" \
  "$good_root/crates/panicscan-core/src"

cat >"$bad_root/crates/panicscan-core/src/lib.rs" <<'BAD'
#[cfg(target_arch = "x86_64")]
pub fn only_x64() {
    let _ = "nvidia-smi";
}
BAD

cat >"$version_bad_root/crates/panicscan-core/src/lib.rs" <<'BAD_VERSION'
pub fn only_current_desktop_os_release() -> &'static str {
    "Windows 11 only"
}
BAD_VERSION

cat >"$collector_bad_root/crates/panicscan-core/src/collectors/linux_persistence.rs" <<'BAD_COLLECTOR'
pub fn collect_linux_persistence() -> Vec<String> {
    std::fs::read_dir("/maybe-missing").unwrap();
    Vec::new()
}
BAD_COLLECTOR

cat >"$good_root/crates/panicscan-core/src/lib.rs" <<'GOOD'
pub fn capability_based() {
    let _ = "portable";
}
GOOD

bad_output="$root/bad.out"
if PANICSCAN_PORTABILITY_AUDIT_ROOT="$bad_root" scripts/portability_contract_audit.sh >"$bad_output" 2>&1; then
  echo "expected portability audit bad fixture to fail" >&2
  exit 1
fi

if ! grep -q 'target_arch' "$bad_output"; then
  echo "expected target_arch portability failure" >&2
  sed -n '1,160p' "$bad_output" >&2
  exit 1
fi

version_bad_output="$root/version-bad.out"
if PANICSCAN_PORTABILITY_AUDIT_ROOT="$version_bad_root" scripts/portability_contract_audit.sh >"$version_bad_output" 2>&1; then
  echo "expected portability audit OS-version bad fixture to fail" >&2
  exit 1
fi

if ! grep -q 'OS release-version' "$version_bad_output"; then
  echo "expected OS release-version portability failure" >&2
  sed -n '1,160p' "$version_bad_output" >&2
  exit 1
fi

collector_bad_output="$root/collector-bad.out"
if PANICSCAN_PORTABILITY_AUDIT_ROOT="$collector_bad_root" scripts/portability_contract_audit.sh >"$collector_bad_output" 2>&1; then
  echo "expected portability audit collector bad fixture to fail" >&2
  exit 1
fi

if ! grep -q 'capability-degradation' "$collector_bad_output"; then
  echo "expected capability-degradation portability failure" >&2
  sed -n '1,160p' "$collector_bad_output" >&2
  exit 1
fi

good_output="$root/good.out"
PANICSCAN_PORTABILITY_AUDIT_ROOT="$good_root" scripts/portability_contract_audit.sh >"$good_output"

if ! grep -q 'portability_contract_audit=passed' "$good_output"; then
  echo "expected portability audit good fixture to pass" >&2
  sed -n '1,160p' "$good_output" >&2
  exit 1
fi

echo "portability_contract_audit_fixture_test=passed"
echo "fixture_root=$root"
