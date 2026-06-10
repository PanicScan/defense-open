#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/github_release_evidence_fetch.sh [OWNER/REPO] [RUN_ID] [EVIDENCE_ROOT]

Downloads the three public release evidence artifacts from a GitHub Actions
Release run and runs scripts/release_evidence_audit.sh against them.

Environment overrides:
  PANICSCAN_GITHUB_REPO            OWNER/REPO; defaults to Cargo.toml repository URL
  PANICSCAN_GITHUB_RELEASE_RUN_ID  GitHub Actions run id; defaults to latest successful Release run
  PANICSCAN_RELEASE_EVIDENCE_ROOT  download root; defaults to /tmp/panicscan-release-evidence-<run-id>
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

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
  repo="$(derive_repo_from_cargo)"
fi

run_id="${2:-${PANICSCAN_GITHUB_RELEASE_RUN_ID:-}}"
evidence_root="${3:-${PANICSCAN_RELEASE_EVIDENCE_ROOT:-}}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required to download GitHub Actions release evidence artifacts" >&2
  exit 1
fi

if ! gh repo view "$repo" --json nameWithOwner,url,defaultBranchRef >/dev/null; then
  echo "GitHub repository is not visible to gh: $repo" >&2
  echo "Create/push the repo or set PANICSCAN_GITHUB_REPO to the correct OWNER/REPO." >&2
  exit 1
fi

if [[ -z "$run_id" ]]; then
  run_id="$(
    gh run list \
      --repo "$repo" \
      --workflow Release \
      --status success \
      --limit 1 \
      --json databaseId \
      --jq '.[0].databaseId // ""'
  )"
fi

if [[ -z "$run_id" ]]; then
  echo "no successful Release workflow run found for $repo" >&2
  echo "Trigger a signed tag release first or pass PANICSCAN_GITHUB_RELEASE_RUN_ID." >&2
  exit 1
fi

if [[ -z "$evidence_root" ]]; then
  evidence_root="/tmp/panicscan-release-evidence-$run_id"
fi

expected_artifacts=(
  panicscan-windows-x64-release-evidence
  panicscan-macos-universal-release-evidence
  panicscan-linux-x64-release-evidence
)

mkdir -p "$evidence_root"

if find "$evidence_root" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  echo "release evidence root is not empty: $evidence_root" >&2
  echo "Use a new EVIDENCE_ROOT." >&2
  exit 1
fi

gh run view "$run_id" \
  --repo "$repo" \
  --json databaseId,name,displayTitle,headBranch,headSha,status,conclusion,createdAt,updatedAt,url \
  >"$evidence_root/github-run.json"

download_args=()
for artifact in "${expected_artifacts[@]}"; do
  download_args+=(--name "$artifact")
done

gh run download "$run_id" \
  --repo "$repo" \
  --dir "$evidence_root" \
  "${download_args[@]}"

scripts/release_evidence_audit.sh "$evidence_root"

cat <<SUMMARY
github_release_evidence_fetch=passed
repo=$repo
run_id=$run_id
evidence_root=$evidence_root
artifacts=${expected_artifacts[*]}
SUMMARY
