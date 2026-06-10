#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/repository_readiness_audit.sh [OWNER/REPO]

Audits whether this workspace is ready to produce real GitHub CI and release
evidence. It does not create repositories, commit, push, or modify GitHub state.

Environment overrides:
  PANICSCAN_GITHUB_REPO  OWNER/REPO; defaults to Cargo.toml repository URL
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

failures=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=1
}

derive_repo_from_cargo() {
  python3 <<'PY'
import pathlib
import re
import sys

manifest = pathlib.Path("Cargo.toml")
for line in manifest.read_text(encoding="utf-8").splitlines():
    match = re.match(r'\s*repository\s*=\s*"([^"]+)"\s*$', line)
    if not match:
        continue
    url = match.group(1).strip()
    patterns = [
        r"^https://github\.com/([^/]+/[^/.]+)(?:\.git)?/?$",
        r"^git@github\.com:([^/]+/[^/.]+)(?:\.git)?$",
    ]
    for pattern in patterns:
        repo_match = re.match(pattern, url)
        if repo_match:
            print(repo_match.group(1))
            raise SystemExit(0)
    print(f"unsupported GitHub repository URL in Cargo.toml: {url}", file=sys.stderr)
    raise SystemExit(1)

print("repository field not found in Cargo.toml", file=sys.stderr)
raise SystemExit(1)
PY
}

repo="${1:-${PANICSCAN_GITHUB_REPO:-}}"
if [[ -z "$repo" ]]; then
  if repo="$(derive_repo_from_cargo)"; then
    pass "Cargo.toml repository resolves to $repo"
  else
    fail "could not derive GitHub repository from Cargo.toml"
    repo=""
  fi
fi

for workflow in .github/workflows/ci.yml .github/workflows/release.yml; do
  if [[ -s "$workflow" ]]; then
    pass "workflow exists locally: $workflow"
  else
    fail "workflow is missing locally: $workflow"
  fi
done

if scripts/workflow_contract_audit.sh >/dev/null; then
  pass "local workflow contract audit passes"
else
  fail "local workflow contract audit failed"
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "local git repository exists"
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "$origin_url" ]]; then
    fail "git origin remote is missing"
  else
    pass "git origin remote is set"
    if [[ -n "$repo" ]]; then
      case "$origin_url" in
        *github.com[:/]"$repo".git|*github.com[:/]"$repo")
          pass "git origin remote matches $repo"
          ;;
        *)
          fail "git origin remote does not match $repo: $origin_url"
          ;;
      esac
    fi
  fi
else
  fail "not a git repository: $repo_root"
fi

if ! command -v gh >/dev/null 2>&1; then
  fail "gh CLI is missing"
elif [[ -n "$repo" ]]; then
  if gh repo view "$repo" --json nameWithOwner,url,defaultBranchRef >/dev/null; then
    pass "GitHub repository is visible to gh: $repo"

    if gh api "repos/$repo/actions/workflows/ci.yml" >/dev/null 2>&1; then
      pass "GitHub Actions CI workflow is visible"
    else
      fail "GitHub Actions CI workflow is not visible for $repo"
    fi

    if gh api "repos/$repo/actions/workflows/release.yml" >/dev/null 2>&1; then
      pass "GitHub Actions Release workflow is visible"
    else
      fail "GitHub Actions Release workflow is not visible for $repo"
    fi

    signing_required="$(
      gh variable list --repo "$repo" --json name,value --jq '.[] | select(.name == "PANICSCAN_SIGNING_REQUIRED") | .value' 2>/dev/null || true
    )"
    if [[ "$signing_required" == "1" || "$signing_required" == "true" ]]; then
      pass "PANICSCAN_SIGNING_REQUIRED is enabled"
    else
      fail "PANICSCAN_SIGNING_REQUIRED repository variable is not enabled"
    fi

    macos_notarize="$(
      gh variable list --repo "$repo" --json name,value --jq '.[] | select(.name == "PANICSCAN_MACOS_NOTARIZE") | .value' 2>/dev/null || true
    )"
    if [[ "$macos_notarize" == "1" || "$macos_notarize" == "true" ]]; then
      pass "PANICSCAN_MACOS_NOTARIZE is enabled"
    else
      fail "PANICSCAN_MACOS_NOTARIZE repository variable is not enabled"
    fi

    secret_names="$(
      gh secret list --repo "$repo" --json name --jq '.[].name' 2>/dev/null || true
    )"
    for secret in \
      PANICSCAN_WINDOWS_CERTIFICATE_P12_BASE64 \
      PANICSCAN_WINDOWS_CERTIFICATE_PASSWORD \
      PANICSCAN_MACOS_SIGN_IDENTITY \
      PANICSCAN_MACOS_CERTIFICATE_P12_BASE64 \
      PANICSCAN_MACOS_CERTIFICATE_PASSWORD \
      PANICSCAN_APPLE_ID \
      PANICSCAN_APPLE_TEAM_ID \
      PANICSCAN_APPLE_APP_PASSWORD
    do
      if grep -qx "$secret" <<<"$secret_names"; then
        pass "required signing secret exists: $secret"
      else
        fail "required signing secret is missing: $secret"
      fi
    done
  else
    fail "GitHub repository is not visible to gh: $repo"
  fi
elif command -v gh >/dev/null 2>&1; then
  fail "GitHub repository is unknown; pass OWNER/REPO or set PANICSCAN_GITHUB_REPO"
fi

if [[ "$failures" -ne 0 ]]; then
  echo "repository_readiness_audit=failed" >&2
  exit 1
fi

echo "repository_readiness_audit=passed"
