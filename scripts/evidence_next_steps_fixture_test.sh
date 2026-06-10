#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_EVIDENCE_NEXT_STEPS_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-evidence-next-steps.XXXXXX)}"
fake_bin="$root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "api" ]]; then
  endpoint="${2:-}"
  jq_expr=""
  while [[ "$#" -gt 0 ]]; do
    if [[ "${1:-}" == "--jq" ]]; then
      jq_expr="${2:-}"
      break
    fi
    shift
  done

  case "$endpoint:$jq_expr" in
    *actions/runs/123*:*status*) echo "completed" ;;
    *actions/runs/123*:*conclusion*) echo "success" ;;
    *actions/runs/123*:*html_url*) echo "https://example.test/actions/runs/123" ;;
    *actions/workflows/release.yml/runs*:*id*) ;;
    *actions/workflows/release.yml/runs*:*status*) ;;
    *actions/workflows/release.yml/runs*:*conclusion*) ;;
    *actions/workflows/release.yml/runs*:*html_url*) ;;
    *) ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "variable" && "${2:-}" == "list" ]]; then
  if [[ "${PANICSCAN_FAKE_SIGNING_READY:-0}" == "1" ]]; then
    printf 'PANICSCAN_SIGNING_REQUIRED\ttrue\n'
    printf 'PANICSCAN_MACOS_NOTARIZE\ttrue\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "secret" && "${2:-}" == "list" ]]; then
  if [[ "${PANICSCAN_FAKE_SIGNING_READY:-0}" == "1" ]]; then
    cat <<'SECRETS'
PANICSCAN_WINDOWS_CERTIFICATE_P12_BASE64
PANICSCAN_WINDOWS_CERTIFICATE_PASSWORD
PANICSCAN_MACOS_SIGN_IDENTITY
PANICSCAN_MACOS_CERTIFICATE_P12_BASE64
PANICSCAN_MACOS_CERTIFICATE_PASSWORD
PANICSCAN_APPLE_ID
PANICSCAN_APPLE_TEAM_ID
PANICSCAN_APPLE_APP_PASSWORD
SECRETS
  fi
  exit 0
fi

echo "unexpected fake gh invocation: $*" >&2
exit 1
SH
chmod +x "$fake_bin/gh"

blocked_output="$root/blocked.txt"
PATH="$fake_bin:$PATH" scripts/evidence_next_steps.sh example/repo 123 >"$blocked_output"

for expected in \
  "latest_ci_run_id=123" \
  "latest_ci_status=completed" \
  "latest_ci_conclusion=success" \
  "latest_ci_url=https://example.test/actions/runs/123" \
  "release_variable_PANICSCAN_SIGNING_REQUIRED=missing_or_disabled" \
  "release_secret_PANICSCAN_WINDOWS_CERTIFICATE_P12_BASE64=missing" \
  "signing_preflight=blocked_missing_config" \
  "physical_usb=scripts/physical_usb_acceptance.sh <drive-or-mount-path>"
do
  if ! grep -Fq "$expected" "$blocked_output"; then
    echo "expected evidence next steps blocked output to contain: $expected" >&2
    sed -n '1,220p' "$blocked_output" >&2
    exit 1
  fi
done

ready_output="$root/ready.txt"
PANICSCAN_FAKE_SIGNING_READY=1 \
  PATH="$fake_bin:$PATH" \
  scripts/evidence_next_steps.sh example/repo 123 >"$ready_output"

for expected in \
  "release_variable_PANICSCAN_SIGNING_REQUIRED=present" \
  "release_variable_PANICSCAN_MACOS_NOTARIZE=present" \
  "release_secret_PANICSCAN_APPLE_APP_PASSWORD=present" \
  "signing_preflight=ready_to_tag_release"
do
  if ! grep -Fq "$expected" "$ready_output"; then
    echo "expected evidence next steps ready output to contain: $expected" >&2
    sed -n '1,220p' "$ready_output" >&2
    exit 1
  fi
done

echo "evidence_next_steps_fixture_test=passed"
echo "root=$root"
