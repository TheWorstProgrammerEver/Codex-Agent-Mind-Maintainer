#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-schedule.sh [--dry-run]

Installs a systemd service and timer for Codex Agent Mind Maintainer.

Environment:
  TARGET_USER          User that runs the service. Default: sudo user or current user.
  MAINTAINER_DIR      Maintainer directory. Default: parent of this script.
  UNIT_BASE           Unit name prefix. Default: codex-agent-mind-maintainer.
  SYSTEMD_DIR         Unit install dir. Default: /etc/systemd/system.
  SCHEDULE_INTERVAL   Timer interval. Default: 6h.
  ON_BOOT_SEC         First run delay after boot. Default: 10min.
  ACCURACY_SEC        Timer accuracy. Default: 5min.
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

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MAINTAINER_DIR:-}" ]]; then
  maintainer_dir="$(CDPATH= cd -- "$MAINTAINER_DIR" && pwd)"
else
  maintainer_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
fi
unit_base="${UNIT_BASE:-codex-agent-mind-maintainer}"
systemd_dir="${SYSTEMD_DIR:-/etc/systemd/system}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
install_bin="${INSTALL_BIN:-install}"
target_user="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
schedule_interval="${SCHEDULE_INTERVAL:-6h}"
on_boot_sec="${ON_BOOT_SEC:-10min}"
accuracy_sec="${ACCURACY_SEC:-5min}"
service_unit="${unit_base}.service"
timer_unit="${unit_base}.timer"
service_path="${systemd_dir}/${service_unit}"
timer_path="${systemd_dir}/${timer_unit}"

if [[ ! -x "$maintainer_dir/scripts/maintain.sh" ]]; then
  printf 'Maintainer script is not executable: %s\n' "$maintainer_dir/scripts/maintain.sh" >&2
  exit 1
fi

if ! target_home="$(getent passwd "$target_user" | cut -d: -f6)"; then
  printf 'Unable to determine home directory for user: %s\n' "$target_user" >&2
  exit 1
fi

if [[ -z "$schedule_interval" ]]; then
  printf 'SCHEDULE_INTERVAL must not be empty.\n' >&2
  exit 1
fi

if [[ "$systemd_dir" == "/etc/systemd/system" && "$(id -u)" -ne 0 && "$dry_run" -eq 0 ]]; then
  printf 'Run this script as root when installing into %s\n' "$systemd_dir" >&2
  exit 1
fi

tmp_service="$(mktemp --suffix=.service)"
tmp_timer="$(mktemp --suffix=.timer)"
cleanup() {
  rm -f "$tmp_service" "$tmp_timer"
}
trap cleanup EXIT

cat >"$tmp_service" <<EOF
[Unit]
Description=Codex Agent Mind Maintainer
Documentation=https://github.com/TheWorstProgrammerEver/Codex-Agent-Mind-Maintainer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$target_user
WorkingDirectory=$maintainer_dir
Environment=CODEX_MIND_MAINTAINER_HOME=$target_home
Environment=CODEX_MIND_MAINTAINER_WORKSPACE=$target_home
EnvironmentFile=-$target_home/.config/codex-agent-mind-maintainer/env
ExecStart=$maintainer_dir/scripts/maintain.sh
TimeoutStartSec=infinity
KillMode=control-group
EOF

cat >"$tmp_timer" <<EOF
[Unit]
Description=Run Codex Agent Mind Maintainer

[Timer]
OnBootSec=$on_boot_sec
OnUnitInactiveSec=$schedule_interval
AccuracySec=$accuracy_sec
Persistent=true
Unit=$service_unit

[Install]
WantedBy=timers.target
EOF

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$tmp_service" "$tmp_timer"
fi

if [[ "$dry_run" -eq 1 ]]; then
  printf 'Would install %s and %s\n\n' "$service_path" "$timer_path"
  printf '%s\n' "--- $service_unit ---"
  cat "$tmp_service"
  printf '\n%s\n' "--- $timer_unit ---"
  cat "$tmp_timer"
  exit 0
fi

mkdir -p "$systemd_dir"
"$install_bin" -D -m 0644 "$tmp_service" "$service_path"
"$install_bin" -D -m 0644 "$tmp_timer" "$timer_path"

"$systemctl_bin" daemon-reload
"$systemctl_bin" enable --now "$timer_unit"
"$systemctl_bin" restart "$timer_unit"
"$systemctl_bin" reset-failed "$service_unit" "$timer_unit" >/dev/null 2>&1 || true

printf 'Installed %s and %s\n' "$service_path" "$timer_path"
printf 'Timer enabled and started: %s\n' "$timer_unit"
printf 'Default interval: %s\n' "$schedule_interval"
printf 'Inspect with: %s status %s && %s list-timers %s\n' "$systemctl_bin" "$timer_unit" "$systemctl_bin" "$timer_unit"
