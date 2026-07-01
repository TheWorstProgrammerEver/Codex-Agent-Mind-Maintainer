#!/usr/bin/env bash
set -euo pipefail

target_user="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"

if ! target_home="$(getent passwd "$target_user" | cut -d: -f6)"; then
  printf 'Unable to determine home directory for user: %s\n' "$target_user" >&2
  exit 1
fi

unit_base="${UNIT_BASE:-codex-agent-mind-maintainer}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
state_dir="${CODEX_MIND_MAINTAINER_STATE_DIR:-$target_home/.local/state/codex-agent-mind-maintainer}"
last_run="$state_dir/last-run.md"
logs_dir="$state_dir/logs"

printf 'Codex Agent Mind Maintainer\n'
printf 'State: %s\n' "$state_dir"
printf 'Last run: %s\n' "$last_run"
printf '\n'

if command -v "$systemctl_bin" >/dev/null 2>&1; then
  "$systemctl_bin" status "${unit_base}.timer" --no-pager || true
  printf '\n'
  "$systemctl_bin" list-timers "${unit_base}.timer" --no-pager || true
  printf '\n'
fi

if [[ -f "$last_run" ]]; then
  cat "$last_run"
else
  printf 'No last-run summary exists yet.\n'
fi

printf '\nRecent logs:\n'
if [[ -d "$logs_dir" ]]; then
  find "$logs_dir" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM %p\n' |
    sort -r |
    sed -n '1,10p'
else
  printf 'No log directory exists yet.\n'
fi
