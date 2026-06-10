#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_AI_SAFETY_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-ai-safety-fixture.XXXXXX)}"
bad_root="$root/bad"
good_root="$root/good"

mkdir -p "$bad_root/crates/panicscan-core/src" "$good_root/crates/panicscan-core/src"

cat >"$bad_root/crates/panicscan-core/src/lib.rs" <<'BAD'
pub fn unsafe_agent_direction() -> &'static str {
    "autonomous exploit payload sharing with self propagation"
}
BAD

cat >"$good_root/crates/panicscan-core/src/lib.rs" <<'GOOD'
pub fn defensive_agent_direction() -> &'static str {
    "signed rule bundle mirroring with redacted telemetry"
}
GOOD

bad_output="$root/bad.out"
if PANICSCAN_AI_SAFETY_AUDIT_ROOT="$bad_root" scripts/ai_safety_contract_audit.sh >"$bad_output" 2>&1; then
  echo "expected AI safety audit bad fixture to fail" >&2
  exit 1
fi

if ! grep -q 'AI safety contract' "$bad_output"; then
  echo "expected AI safety contract failure" >&2
  sed -n '1,160p' "$bad_output" >&2
  exit 1
fi

good_output="$root/good.out"
PANICSCAN_AI_SAFETY_AUDIT_ROOT="$good_root" scripts/ai_safety_contract_audit.sh >"$good_output"

if ! grep -q 'ai_safety_contract_audit=passed' "$good_output"; then
  echo "expected AI safety audit good fixture to pass" >&2
  sed -n '1,160p' "$good_output" >&2
  exit 1
fi

echo "ai_safety_contract_audit_fixture_test=passed"
echo "fixture_root=$root"
