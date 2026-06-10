#!/usr/bin/env bash

resolve_panicscan_bin() {
  local profile="${1:-debug}"

  if [[ -n "${PANICSCAN_BIN:-}" ]]; then
    printf '%s\n' "$PANICSCAN_BIN"
    return 0
  fi

  local candidate
  for candidate in "target/$profile/panicscan" "target/$profile/panicscan.exe"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "could not find target/$profile/panicscan or target/$profile/panicscan.exe" >&2
  return 1
}
