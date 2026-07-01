#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: uninstall-schedule.sh [--dry-run]

Disables and removes the Codex Agent Mind Maintainer systemd service and timer.

Environment:
  UNIT_BASE     Unit name prefix. Default: codex-agent-mind-maintainer.
  SYSTEMD_DIR   Unit install dir. Default: /etc/systemd/system.
EOF
}

dry_run=0

while (($#)); do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

unit_base="${UNIT_BASE:-codex-agent-mind-maintainer}"
systemd_dir="${SYSTEMD_DIR:-/etc/systemd/system}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
service_unit="${unit_base}.service"
timer_unit="${unit_base}.timer"
service_path="${systemd_dir}/${service_unit}"
timer_path="${systemd_dir}/${timer_unit}"

if [[ "$systemd_dir" == "/etc/systemd/system" && "$(id -u)" -ne 0 && "$dry_run" -eq 0 ]]; then
  printf 'Run this script as root when uninstalling from %s\n' "$systemd_dir" >&2
  exit 1
fi

if [[ "$dry_run" -eq 1 ]]; then
  printf 'Would disable and remove:\n'
  printf -- '- %s\n' "$service_path"
  printf -- '- %s\n' "$timer_path"
  exit 0
fi

"$systemctl_bin" disable --now "$timer_unit" >/dev/null 2>&1 || true
"$systemctl_bin" stop "$service_unit" >/dev/null 2>&1 || true

rm -f "$service_path" "$timer_path"

"$systemctl_bin" daemon-reload
"$systemctl_bin" reset-failed "$service_unit" "$timer_unit" >/dev/null 2>&1 || true

printf 'Removed %s and %s\n' "$service_path" "$timer_path"
printf 'Timer disabled: %s\n' "$timer_unit"
