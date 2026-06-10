#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

stdout_path="${PANICSCAN_SYSTEM_CRITICAL_STDOUT:-/tmp/panicscan-system-critical-policy.stdout}"
stderr_path="${PANICSCAN_SYSTEM_CRITICAL_STDERR:-/tmp/panicscan-system-critical-policy.stderr}"

mkdir -p "$(dirname "$stdout_path")" "$(dirname "$stderr_path")"

cargo test -p panicscan-core system_critical_file_policy_uses_manual_review -- --nocapture \
  >"$stdout_path" 2>"$stderr_path"

if ! grep -q "system_critical_file_policy_uses_manual_review" "$stdout_path"; then
  echo "expected focused system-critical policy test output" >&2
  exit 1
fi

if ! grep -Eq "test result: ok\. [1-9][0-9]* passed" "$stdout_path"; then
  echo "expected at least one passing system-critical policy test" >&2
  exit 1
fi

cat <<SUMMARY
system_critical_policy_smoke=passed
test=system_critical_file_policy_uses_manual_review
stdout=$stdout_path
stderr=$stderr_path
SUMMARY
