#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
tmp_root="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

home_dir="$tmp_root/home"
state_dir="$tmp_root/state"
bin_dir="$tmp_root/bin"
mkdir -p "$home_dir" "$state_dir/logs" "$bin_dir"

fake_codex="$bin_dir/fake-codex"
cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

last_message=""
while (($#)); do
  case "$1" in
    --output-last-message)
      last_message="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'fake codex streaming output\n'

if [[ -n "$last_message" ]]; then
  cat >"$last_message" <<'MSG'
## Changed

fake final message
MSG
fi
EOF
chmod +x "$fake_codex"

for index in 1 2 3 4 5; do
  old_log="$state_dir/logs/old-$index.log"
  printf 'old log %s\n' "$index" >"$old_log"
  touch -d '120 days ago' "$old_log"
done

output="$(
  CODEX_BIN="$fake_codex" \
  CODEX_MIND_MAINTAINER_HOME="$home_dir" \
  CODEX_MIND_MAINTAINER_WORKSPACE="$home_dir" \
  CODEX_MIND_MAINTAINER_STATE_DIR="$state_dir" \
  CODEX_MIND_MAINTAINER_LOG_RETENTION_DAYS=1 \
  CODEX_MIND_MAINTAINER_MIN_LOGS_TO_KEEP=2 \
  "$repo_dir/scripts/maintain.sh"
)"

printf '%s\n' "$output" | grep -q 'fake codex streaming output'
printf '%s\n' "$output" | grep -q 'Pruned 4 old maintainer log'

latest_log="$(find "$state_dir/logs" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' | sort -nr | sed -n '1s/^[^ ]* //p')"
grep -q 'fake codex streaming output' "$latest_log"
grep -q 'fake final message' "$state_dir/last-run.md"

old_log_count="$(find "$state_dir/logs" -maxdepth 1 -type f -name 'old-*.log' | wc -l)"
if [[ "$old_log_count" -ne 1 ]]; then
  printf 'Expected retention to keep exactly 1 old log, found %s.\n' "$old_log_count" >&2
  exit 1
fi

grep -q 'Local review artifacts are the default for routine skipped durable-note' "$repo_dir/prompt.md"
grep -q 'Do not create a Linear issue merely' "$repo_dir/prompt.md"
grep -q 'because a local-authoritative file differs' "$repo_dir/prompt.md"
grep -q 'Do not put agent pickup labels' "$repo_dir/prompt.md"
grep -q 'If a similar Backlog issue already exists, update or reference it' "$repo_dir/prompt.md"

printf 'maintainer shell tests passed\n'
