#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
tmp_root="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

target_user="$(id -un)"
maintainer_dir="$tmp_root/maintainer"
private_runtime_dir="$tmp_root/private-node/bin"
unresolvable_runtime_dir="$tmp_root/unresolvable-node/bin"
systemd_dir="$tmp_root/systemd"
systemctl_log="$tmp_root/systemctl.log"
unresolvable_error="$tmp_root/unresolvable-node.err"
canary_marker="$tmp_root/private-node-used"
service_marker="$tmp_root/service-reached"
host_node="$(readlink -f -- "$(command -v node)")"
unit_base="codex-agent-mind-maintainer-test"

mkdir -p \
  "$maintainer_dir/scripts" \
  "$private_runtime_dir" \
  "$unresolvable_runtime_dir" \
  "$systemd_dir"

cat >"$private_runtime_dir/node-v22-custom" <<EOF
#!/bin/bash
set -euo pipefail
printf 'private runtime used\n' >"$canary_marker"
export PRIVATE_NODE_CANARY=1
exec "$host_node" "\$@"
EOF
chmod +x "$private_runtime_dir/node-v22-custom"
ln -s node-v22-custom "$private_runtime_dir/node"

cp "$private_runtime_dir/node-v22-custom" "$unresolvable_runtime_dir/node-v22-custom"

cat >"$maintainer_dir/scripts/maintain.sh" <<EOF
#!/usr/bin/env node
if (process.env.PRIVATE_NODE_CANARY !== "1") {
  process.exit(23);
}
require("node:fs").writeFileSync("$service_marker", "service reached\n");
EOF
chmod +x "$maintainer_dir/scripts/maintain.sh"

fake_systemctl="$tmp_root/systemctl"
cat >"$fake_systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$systemctl_log"
EOF
chmod +x "$fake_systemctl"

if NODE_BIN="$unresolvable_runtime_dir/node-v22-custom" \
  TARGET_USER="$target_user" \
  MAINTAINER_DIR="$maintainer_dir" \
  UNIT_BASE="$unit_base" \
  SYSTEMD_DIR="$systemd_dir" \
  SYSTEMCTL_BIN="$fake_systemctl" \
    "$repo_dir/scripts/install-schedule.sh" --dry-run >/dev/null 2>"$unresolvable_error"
then
  printf 'Expected NODE_BIN without a matching node command to be rejected.\n' >&2
  exit 1
fi
grep -q '^NODE_BIN directory must expose node as the selected executable:' \
  "$unresolvable_error"

install_fixture() {
  NODE_BIN="$private_runtime_dir/node-v22-custom" \
  TARGET_USER="$target_user" \
  MAINTAINER_DIR="$maintainer_dir" \
  UNIT_BASE="$unit_base" \
  SYSTEMD_DIR="$systemd_dir" \
  SYSTEMCTL_BIN="$fake_systemctl" \
  SCHEDULE_INTERVAL=17min \
  ON_BOOT_SEC=11min \
  ACCURACY_SEC=1min \
    "$repo_dir/scripts/install-schedule.sh" >/dev/null
}

install_fixture

service_unit="$systemd_dir/$unit_base.service"
timer_unit="$systemd_dir/$unit_base.timer"
timer_hash_before="$(sha256sum "$timer_unit" | cut -d' ' -f1)"

path_line_count="$(grep -c 'PATH=' "$service_unit")"
if [[ "$path_line_count" -ne 1 ]]; then
  printf 'Expected exactly one controlled PATH assignment, found %s.\n' "$path_line_count" >&2
  exit 1
fi

service_path="$(sed -n 's|^ExecStart=/usr/bin/env "PATH=\([^"]*\)" .*$|\1|p' "$service_unit")"
if [[ "$service_path" != "$private_runtime_dir:"* ]]; then
  printf 'Expected the selected private Node runtime to lead the service PATH.\n' >&2
  exit 1
fi

if env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  "$maintainer_dir/scripts/maintain.sh" >/dev/null 2>&1
then
  printf 'Expected the canary to reject the ordinary system PATH.\n' >&2
  exit 1
fi

env -i PATH="$service_path" "$maintainer_dir/scripts/maintain.sh"
grep -q '^private runtime used$' "$canary_marker"
grep -q '^service reached$' "$service_marker"

install_fixture

timer_hash_after="$(sha256sum "$timer_unit" | cut -d' ' -f1)"
if [[ "$timer_hash_before" != "$timer_hash_after" ]]; then
  printf 'Expected repeat installation to preserve timer semantics.\n' >&2
  exit 1
fi

if [[ "$(grep -c 'PATH=' "$service_unit")" -ne 1 ]]; then
  printf 'Expected repeat installation to retain one controlled PATH assignment.\n' >&2
  exit 1
fi

restart_count="$(grep -c '^restart codex-agent-mind-maintainer-test.timer$' "$systemctl_log")"
if [[ "$restart_count" -ne 2 ]]; then
  printf 'Expected every installation to re-arm the timer explicitly.\n' >&2
  exit 1
fi

enable_count="$(grep -c '^enable --now codex-agent-mind-maintainer-test.timer$' "$systemctl_log")"
if [[ "$enable_count" -ne 2 ]]; then
  printf 'Expected every installation to preserve timer enablement.\n' >&2
  exit 1
fi

printf 'schedule installer tests passed\n'
