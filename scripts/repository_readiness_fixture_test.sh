#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

root="${PANICSCAN_REPOSITORY_READINESS_FIXTURE_ROOT:-$(mktemp -d /tmp/panicscan-repository-readiness.XXXXXX)}"
fake_bin="$root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo '{"nameWithOwner":"kingkyylian/panic-scan","url":"https://github.com/kingkyylian/panic-scan","defaultBranchRef":{"name":"main"}}'
  exit 0
fi

if [[ "${1:-}" == "api" ]]; then
  case "${2:-}" in
    repos/kingkyylian/panic-scan/actions/workflows/ci.yml|repos/kingkyylian/panic-scan/actions/workflows/release.yml)
      echo '{}'
      exit 0
      ;;
  esac
fi

if [[ "${1:-}" == "variable" && "${2:-}" == "list" ]]; then
  if [[ "${PANICSCAN_FAKE_READINESS_READY:-0}" == "1" ]]; then
    args="$*"
    if [[ "$args" == *"PANICSCAN_SIGNING_REQUIRED"* || "$args" == *"PANICSCAN_MACOS_NOTARIZE"* ]]; then
      echo "true"
    fi
  fi
  exit 0
fi

if [[ "${1:-}" == "secret" && "${2:-}" == "list" ]]; then
  if [[ "${PANICSCAN_FAKE_READINESS_READY:-0}" == "1" ]]; then
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
if PATH="$fake_bin:$PATH" scripts/repository_readiness_audit.sh kingkyylian/panic-scan >"$blocked_output" 2>&1; then
  echo "expected repository readiness audit to fail when signing configuration is missing" >&2
  exit 1
fi

for expected in \
  "PASS GitHub repository is visible to gh: kingkyylian/panic-scan" \
  "PASS GitHub Actions CI workflow is visible" \
  "PASS GitHub Actions Release workflow is visible" \
  "FAIL PANICSCAN_SIGNING_REQUIRED repository variable is not enabled" \
  "FAIL PANICSCAN_MACOS_NOTARIZE repository variable is not enabled" \
  "FAIL required signing secret is missing: PANICSCAN_WINDOWS_CERTIFICATE_P12_BASE64" \
  "repository_readiness_audit=failed"
do
  if ! grep -Fq "$expected" "$blocked_output"; then
    echo "expected blocked readiness output to contain: $expected" >&2
    sed -n '1,220p' "$blocked_output" >&2
    exit 1
  fi
done

ready_output="$root/ready.txt"
PANICSCAN_FAKE_READINESS_READY=1 \
  PATH="$fake_bin:$PATH" \
  scripts/repository_readiness_audit.sh kingkyylian/panic-scan >"$ready_output" 2>&1

for expected in \
  "PASS PANICSCAN_SIGNING_REQUIRED is enabled" \
  "PASS PANICSCAN_MACOS_NOTARIZE is enabled" \
  "PASS required signing secret exists: PANICSCAN_APPLE_APP_PASSWORD" \
  "repository_readiness_audit=passed"
do
  if ! grep -Fq "$expected" "$ready_output"; then
    echo "expected ready readiness output to contain: $expected" >&2
    sed -n '1,220p' "$ready_output" >&2
    exit 1
  fi
done

echo "repository_readiness_fixture_test=passed"
echo "root=$root"
