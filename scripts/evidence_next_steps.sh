#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/evidence_next_steps.sh [OWNER/REPO] [CI_RUN_ID]

Print a read-only status summary and concrete next commands for the remaining
MVP evidence blockers: real CI evidence, physical removable USB evidence, and
public signed release evidence.

Environment overrides:
  PANICSCAN_GITHUB_REPO  OWNER/REPO; defaults to Cargo.toml repository URL
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

manifest = pathlib.Path("Cargo.toml")
for line in manifest.read_text(encoding="utf-8").splitlines():
    match = re.match(r'\s*repository\s*=\s*"([^"]+)"\s*$', line)
    if not match:
        continue
    url = match.group(1).strip()
    for pattern in [
        r"^https://github\.com/([^/]+/[^/.]+)(?:\.git)?/?$",
        r"^git@github\.com:([^/]+/[^/.]+)(?:\.git)?$",
    ]:
        repo_match = re.match(pattern, url)
        if repo_match:
            print(repo_match.group(1))
            raise SystemExit(0)
raise SystemExit(1)
PY
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

quote_command_arg() {
  printf '%q' "$1"
}

repo="${1:-${PANICSCAN_GITHUB_REPO:-}}"
if [[ -z "$repo" ]]; then
  repo="$(derive_repo_from_cargo 2>/dev/null || true)"
fi
ci_run_id="${2:-}"

section() {
  printf '\n[%s]\n' "$1"
}

gh_api() {
  local attempt
  for attempt in 1 2 3; do
    if gh api "$@"; then
      return 0
    fi
    sleep "$attempt"
  done
  return 1
}

latest_ci_run() {
  local field="$1"
  if [[ -z "$repo" ]] || ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "$ci_run_id" ]]; then
    gh_api "repos/$repo/actions/runs/$ci_run_id" \
      --jq ".$field // empty" 2>/dev/null || true
  else
    gh_api "repos/$repo/actions/runs" \
      --jq "[.workflow_runs[] | select(.name == \"CI\")][0].$field // empty" 2>/dev/null || true
  fi
}

latest_release_run() {
  local field="$1"
  if [[ -z "$repo" ]] || ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  gh_api "repos/$repo/actions/workflows/release.yml/runs?per_page=1" \
    --jq ".workflow_runs[0].$field // empty" 2>/dev/null || true
}

print_repo_status() {
  section "repo"
  printf 'repo=%s\n' "${repo:-unknown}"
  printf 'branch=%s\n' "$(git branch --show-current 2>/dev/null || printf 'unknown')"
  printf 'head=%s\n' "$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
    printf 'worktree=clean\n'
  else
    printf 'worktree=dirty\n'
  fi
}

print_ci_status() {
  section "ci"
  local run_id status conclusion url
  run_id="${ci_run_id:-$(latest_ci_run id)}"
  status="$(latest_ci_run status)"
  conclusion="$(latest_ci_run conclusion)"
  url="$(latest_ci_run html_url)"
  printf 'latest_ci_run_id=%s\n' "${run_id:-unknown}"
  printf 'latest_ci_status=%s\n' "${status:-unknown}"
  printf 'latest_ci_conclusion=%s\n' "${conclusion:-unknown}"
  printf 'latest_ci_url=%s\n' "${url:-unknown}"
  if [[ -n "$repo" && -n "$run_id" ]]; then
    printf 'ci_evidence_command=%s\n' \
      "scripts/github_ci_evidence_fetch.sh $repo $run_id /tmp/panicscan-ci-evidence-$run_id"
  fi
}

print_release_status() {
  section "release"
  local run_id status conclusion url
  run_id="$(latest_release_run id)"
  status="$(latest_release_run status)"
  conclusion="$(latest_release_run conclusion)"
  url="$(latest_release_run html_url)"
  printf 'latest_release_run_id=%s\n' "${run_id:-none}"
  printf 'latest_release_status=%s\n' "${status:-none}"
  printf 'latest_release_conclusion=%s\n' "${conclusion:-none}"
  printf 'latest_release_url=%s\n' "${url:-none}"

  if [[ -z "$repo" ]] || ! command -v gh >/dev/null 2>&1; then
    printf 'signing_preflight=unknown\n'
    return 0
  fi

  local variables secrets missing=0
  variables="$(gh variable list --repo "$repo" --json name,value --jq '.[] | [.name, .value] | @tsv' 2>/dev/null || true)"
  secrets="$(gh secret list --repo "$repo" --json name --jq '.[].name' 2>/dev/null || true)"

  for variable in PANICSCAN_SIGNING_REQUIRED PANICSCAN_MACOS_NOTARIZE; do
    if awk -F'\t' -v name="$variable" '$1 == name && ($2 == "1" || $2 == "true") { found = 1 } END { exit found ? 0 : 1 }' <<<"$variables"; then
      printf 'release_variable_%s=present\n' "$variable"
    else
      printf 'release_variable_%s=missing_or_disabled\n' "$variable"
      missing=1
    fi
  done

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
    if grep -qx "$secret" <<<"$secrets"; then
      printf 'release_secret_%s=present\n' "$secret"
    else
      printf 'release_secret_%s=missing\n' "$secret"
      missing=1
    fi
  done

  if [[ "$missing" -eq 0 ]]; then
    printf 'signing_preflight=ready_to_tag_release\n'
  else
    printf 'signing_preflight=blocked_missing_config\n'
  fi
}

print_usb_candidates() {
  section "physical_usb_candidates"
  local system found=0
  system="$(uname -s)"

  case "$system" in
    Darwin)
      local volume info removable
      for volume in /Volumes/*; do
        [[ -e "$volume" ]] || continue
        if [[ "$(cd "$volume" 2>/dev/null && pwd -P || printf '%s' "$volume")" == "/" ]]; then
          continue
        fi
        info="$(diskutil info "$volume" 2>/dev/null || true)"
        removable="unknown"
        if grep -Eiq 'Removable Media:[[:space:]]*(Yes|Removable)' <<<"$info"; then
          removable="passed"
        elif grep -Eiq 'Removable Media:' <<<"$info"; then
          removable="failed"
        fi
        printf 'candidate=%s\tremovable=%s\tcommand=scripts/physical_usb_acceptance.sh %s\n' \
          "$volume" "$removable" "$(quote_command_arg "$volume")"
        found=1
      done
      ;;
    Linux)
      if command -v findmnt >/dev/null 2>&1 && command -v lsblk >/dev/null 2>&1; then
        local target source device parent lsblk_output removable
        while read -r target source; do
          [[ "$source" == /dev/* ]] || continue
          device="$(readlink -f "$source" 2>/dev/null || printf '%s' "$source")"
          lsblk_output="$(lsblk -no RM,TRAN "$device" 2>/dev/null || true)"
          parent="$(lsblk -no PKNAME "$device" 2>/dev/null | head -n 1 || true)"
          if [[ -n "$parent" ]]; then
            lsblk_output="$lsblk_output"$'\n'"$(lsblk -no RM,TRAN "/dev/$parent" 2>/dev/null || true)"
          fi
          removable="failed"
          if awk '($1 == "1" || $2 == "usb") { found = 1 } END { exit found ? 0 : 1 }' <<<"$lsblk_output"; then
            removable="passed"
          fi
          printf 'candidate=%s\tremovable=%s\tcommand=scripts/physical_usb_acceptance.sh %s\n' \
            "$target" "$removable" "$(quote_command_arg "$target")"
          found=1
        done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null || true)
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v powershell.exe >/dev/null 2>&1; then
        while IFS=$'\t' read -r drive bus label; do
          [[ -n "$drive" ]] || continue
          local path="/$drive"
          printf 'candidate=%s\tbus_type=%s\tlabel=%s\tcommand=scripts/physical_usb_acceptance.sh %s\n' \
            "$path" "${bus:-unknown}" "${label:-}" "$(quote_command_arg "$path")"
          found=1
        done < <(powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$ErrorActionPreference='SilentlyContinue'; Get-Volume | ForEach-Object { \$v=\$_; \$d=\$v | Get-Partition | Get-Disk; if (\$d.BusType -eq 'USB') { [Console]::WriteLine((\$v.DriveLetter.ToString() + ':' + \"`t\" + \$d.BusType + \"`t\" + \$v.FileSystemLabel)) } }" 2>/dev/null || true)
      fi
      ;;
  esac

  if [[ "$found" -eq 0 ]]; then
    printf 'candidate=none\n'
    printf 'note=mount a real removable USB drive, then rerun this script\n'
  fi
}

print_next_commands() {
  section "next_commands"
  local latest_ci release_root
  latest_ci="${ci_run_id:-$(latest_ci_run id)}"
  release_root="/tmp/panicscan-release-evidence-<RELEASE_RUN_ID>"
  printf 'local_evidence=scripts/platform_evidence_smoke.sh\n'
  if [[ -n "$repo" && -n "$latest_ci" ]]; then
    printf 'ci_evidence=scripts/github_ci_evidence_fetch.sh %s %s /tmp/panicscan-ci-evidence-%s\n' \
      "$repo" "$latest_ci" "$latest_ci"
  fi
  printf 'physical_usb=scripts/physical_usb_acceptance.sh <drive-or-mount-path>\n'
  if [[ -n "$repo" ]]; then
    printf 'set_release_variables=gh variable set PANICSCAN_SIGNING_REQUIRED --repo %s --body true && gh variable set PANICSCAN_MACOS_NOTARIZE --repo %s --body true\n' "$repo" "$repo"
    printf 'set_release_secrets=gh secret set <SECRET_NAME> --repo %s < <secret-file>\n' "$repo"
    printf 'tag_release=git tag <vX.Y.Z> && git push origin <vX.Y.Z>\n'
    printf 'release_evidence=scripts/github_release_evidence_fetch.sh %s <RELEASE_RUN_ID> %s\n' "$repo" "$release_root"
  fi
  printf 'final_gate=PANICSCAN_LOCAL_EVIDENCE_ROOT=/tmp/panicscan-platform-evidence-$(uname -s) PANICSCAN_CI_EVIDENCE_ROOT=/tmp/panicscan-ci-evidence-%s PANICSCAN_PHYSICAL_USB_EVIDENCE_DIR=<physical-usb-evidence-dir> PANICSCAN_RELEASE_EVIDENCE_ROOT=%s scripts/mvp_acceptance_gate.sh\n' "${latest_ci:-<CI_RUN_ID>}" "$release_root"
}

print_repo_status
print_ci_status
print_release_status
print_usb_candidates
print_next_commands
