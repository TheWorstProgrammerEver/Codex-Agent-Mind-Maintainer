#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
tmp_root="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

node "$repo_dir/scripts/preflight-test.mjs"

home_dir="$tmp_root/home"
state_dir="$tmp_root/state"
bin_dir="$tmp_root/bin"
shared_notes_repo="$tmp_root/shared-notes"
skills_repo="$tmp_root/skills"
mkdir -p "$home_dir" "$state_dir/logs" "$bin_dir" "$shared_notes_repo/state" "$skills_repo/example-skill"

cat >"$shared_notes_repo/AGENTS.shared.md" <<'EOF'
# Shared Agents

<!-- BEGIN SHARED_AGENT_GUIDANCE -->
- Shared guidance.
<!-- END SHARED_AGENT_GUIDANCE -->
EOF
printf '# Shared Index\n' >"$shared_notes_repo/INDEX.md"
printf '# Shared Host Template\n' >"$shared_notes_repo/state/HOST.md"
git -C "$shared_notes_repo" init -q
git -C "$shared_notes_repo" config user.email test@example.invalid
git -C "$shared_notes_repo" config user.name "Maintainer Test"
git -C "$shared_notes_repo" add .
git -C "$shared_notes_repo" commit -m "Initial shared notes" >/dev/null

printf '# Example Skill\n' >"$skills_repo/example-skill/SKILL.md"
git -C "$skills_repo" init -q
git -C "$skills_repo" config user.email test@example.invalid
git -C "$skills_repo" config user.name "Maintainer Test"
git -C "$skills_repo" add .
git -C "$skills_repo" commit -m "Initial skills" >/dev/null

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
  CODEX_MIND_MAINTAINER_SHARED_AGENTS_URL="$shared_notes_repo/AGENTS.shared.md" \
  CODEX_MIND_MAINTAINER_SHARED_NOTES_REPO_URL="$shared_notes_repo" \
  CODEX_MIND_MAINTAINER_SKILLS_REPO_URL="$skills_repo" \
  CODEX_MIND_MAINTAINER_LOG_RETENTION_DAYS=1 \
  CODEX_MIND_MAINTAINER_MIN_LOGS_TO_KEEP=2 \
  "$repo_dir/scripts/maintain.sh"
)"

printf '%s\n' "$output" | grep -q 'Preflight status: preflight-worklist'
printf '%s\n' "$output" | grep -q 'fake codex streaming output'
printf '%s\n' "$output" | grep -q 'Pruned 4 old maintainer log'

latest_log="$(find "$state_dir/logs" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' | sort -nr | sed -n '1s/^[^ ]* //p')"
grep -q 'fake codex streaming output' "$latest_log"
grep -q 'fake final message' "$state_dir/last-run.md"
grep -q 'Status: full-maintenance-succeeded' "$state_dir/last-run.md"
grep -q 'Preflight status: preflight-worklist' "$state_dir/last-run.md"
grep -q 'durable-note-missing' "$state_dir/preflight/"*-worklist.md

old_log_count="$(find "$state_dir/logs" -maxdepth 1 -type f -name 'old-*.log' | wc -l)"
if [[ "$old_log_count" -ne 1 ]]; then
  printf 'Expected retention to keep exactly 1 old log, found %s.\n' "$old_log_count" >&2
  exit 1
fi

noop_home="$tmp_root/noop-home"
noop_state="$tmp_root/noop-state"
mkdir -p "$noop_home/codex-notes/state" "$noop_home/.codex/skills"
cat >"$noop_home/AGENTS.md" <<'EOF'
# Local Agents

<!-- BEGIN SHARED_AGENT_GUIDANCE -->
- Shared guidance.
<!-- END SHARED_AGENT_GUIDANCE -->

- Local guidance.
EOF
printf '# Local Index\n' >"$noop_home/codex-notes/INDEX.md"
printf '# Local Host\n' >"$noop_home/codex-notes/state/HOST.md"
cp -R "$skills_repo/example-skill" "$noop_home/.codex/skills/example-skill"
noop_output="$(
  CODEX_BIN="$fake_codex" \
  CODEX_MIND_MAINTAINER_HOME="$noop_home" \
  CODEX_MIND_MAINTAINER_WORKSPACE="$noop_home" \
  CODEX_MIND_MAINTAINER_STATE_DIR="$noop_state" \
  CODEX_MIND_MAINTAINER_SHARED_AGENTS_URL="$shared_notes_repo/AGENTS.shared.md" \
  CODEX_MIND_MAINTAINER_SHARED_NOTES_REPO_URL="$shared_notes_repo" \
  CODEX_MIND_MAINTAINER_SKILLS_REPO_URL="$skills_repo" \
  "$repo_dir/scripts/maintain.sh"
)"
printf '%s\n' "$noop_output" | grep -q 'Mind Maintainer preflight-noop'
grep -q 'Status: preflight-noop' "$noop_state/last-run.md"
if grep -R -q 'fake codex streaming output' "$noop_state/logs"; then
  printf 'Expected no-op preflight to skip codex invocation.\n' >&2
  exit 1
fi

grep -q 'Local review artifacts are the default for routine skipped durable-note' "$repo_dir/prompt.md"
grep -q 'Do not create a Linear issue merely' "$repo_dir/prompt.md"
grep -q 'because a local-authoritative file differs' "$repo_dir/prompt.md"
grep -q 'Do not put agent pickup labels' "$repo_dir/prompt.md"
grep -q 'If a similar Backlog issue already exists, update or reference it' "$repo_dir/prompt.md"
grep -q 'CODEX_MIND_MAINTAINER_PREFLIGHT_WORKLIST' "$repo_dir/prompt.md"

printf 'maintainer shell tests passed\n'
