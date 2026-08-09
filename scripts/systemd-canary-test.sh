#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  printf 'Run this test as root so it can install disposable system units.\n' >&2
  exit 1
fi

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
target_user="${SUDO_USER:-$(id -un)}"
target_group="$(id -gn "$target_user")"
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
unit_base="codex-agent-mind-maintainer-canary-$$"
service_unit="$unit_base.service"
timer_unit="$unit_base.timer"
service_path="/etc/systemd/system/$service_unit"
timer_path="/etc/systemd/system/$timer_unit"
manager_mutated=0
tmp_root="$(mktemp -d --tmpdir codex-agent-mind-maintainer-canary.XXXXXXXXXX)"

cleanup() {
  if [[ "$manager_mutated" -eq 1 ]]; then
    systemctl stop "$service_unit" "$timer_unit" >/dev/null 2>&1 || true
    systemctl disable "$timer_unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$service_unit" "$timer_unit" >/dev/null 2>&1 || true
    rm -f "$service_path" "$timer_path"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

maintainer_dir="$tmp_root/maintainer"
private_runtime_dir="$tmp_root/private-node/bin"
private_marker="$tmp_root/private-node-used"
service_marker="$tmp_root/service-reached"
host_node="${CANARY_NODE_BIN:-}"

if [[ -z "$host_node" ]]; then
  for candidate in \
    /opt/agent-boot/runtime/bin/node \
    "$target_home/.local/bin/node"
  do
    if [[ -x "$candidate" && ! -d "$candidate" ]]; then
      host_node="$candidate"
      break
    fi
  done
fi

if [[ -z "$host_node" ]]; then
  host_node="$(command -v node || true)"
fi

if [[ "$host_node" != /* || ! -x "$host_node" || -d "$host_node" ]]; then
  printf 'CANARY_NODE_BIN must resolve to an executable absolute file: %s\n' \
    "${host_node:-<not found>}" >&2
  exit 1
fi

host_node="$(readlink -f -- "$host_node")"

install -d -o "$target_user" -g "$target_group" -m 0755 \
  "$tmp_root" \
  "$maintainer_dir" \
  "$maintainer_dir/scripts" \
  "$tmp_root/private-node" \
  "$private_runtime_dir"

cat >"$private_runtime_dir/node-v22-custom" <<EOF
#!/bin/bash
set -euo pipefail
printf 'private runtime used\n' >"$private_marker"
export PRIVATE_NODE_CANARY=1
exec "$host_node" "\$@"
EOF
ln -s node-v22-custom "$private_runtime_dir/node"

cat >"$maintainer_dir/scripts/maintain.sh" <<EOF
#!/usr/bin/env node
if (process.env.PRIVATE_NODE_CANARY !== "1") {
  process.exit(23);
}
require("node:fs").writeFileSync("$service_marker", "service reached\n");
EOF

chown "$target_user:$target_group" \
  "$private_runtime_dir/node-v22-custom" \
  "$private_runtime_dir/node" \
  "$maintainer_dir/scripts/maintain.sh"
chmod 0755 \
  "$private_runtime_dir/node-v22-custom" \
  "$maintainer_dir/scripts/maintain.sh"

install_fixture() {
  NODE_BIN="$private_runtime_dir/node-v22-custom" \
  TARGET_USER="$target_user" \
  MAINTAINER_DIR="$maintainer_dir" \
  UNIT_BASE="$unit_base" \
  SCHEDULE_INTERVAL=47min \
  ON_BOOT_SEC=43min \
  ACCURACY_SEC=1min \
    "$repo_dir/scripts/install-schedule.sh" >/dev/null
}

manager_mutated=1
install_fixture
systemd-analyze verify "$service_path" "$timer_path"
timer_hash_before="$(sha256sum "$timer_path" | cut -d' ' -f1)"

install_fixture
timer_hash_after="$(sha256sum "$timer_path" | cut -d' ' -f1)"

if [[ "$timer_hash_before" != "$timer_hash_after" ]]; then
  printf 'Repeat installation changed the intended timer unit.\n' >&2
  exit 1
fi

if [[ "$(grep -c 'PATH=' "$service_path")" -ne 1 ]]; then
  printf 'Repeat installation did not leave exactly one controlled PATH assignment.\n' >&2
  exit 1
fi

systemctl is-enabled --quiet "$timer_unit"
systemctl is-active --quiet "$timer_unit"

next_monotonic="$(systemctl show "$timer_unit" -p NextElapseUSecMonotonic --value)"
next_realtime="$(systemctl show "$timer_unit" -p NextElapseUSecRealtime --value)"
is_finite_trigger() {
  case "$1" in
    ''|0|infinity|n/a|-) return 1 ;;
    *) return 0 ;;
  esac
}

if ! is_finite_trigger "$next_monotonic" && ! is_finite_trigger "$next_realtime"; then
  printf 'Timer has no finite next trigger: monotonic=%s realtime=%s\n' \
    "$next_monotonic" "$next_realtime" >&2
  exit 1
fi

systemctl start "$service_unit"

grep -q '^private runtime used$' "$private_marker"
grep -q '^service reached$' "$service_marker"
[[ "$(systemctl show "$service_unit" -p Result --value)" == success ]]
[[ "$(systemctl show "$service_unit" -p ExecMainStatus --value)" == 0 ]]

printf '%s\n' \
  'systemd canary passed: static verification, private runtime start, repeat install, and finite timer trigger'
