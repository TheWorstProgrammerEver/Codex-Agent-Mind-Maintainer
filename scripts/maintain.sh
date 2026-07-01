#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: maintain.sh [--dry-run]

Starts one Codex Agent Mind Maintainer run.

Environment:
  CODEX_BIN                              Codex executable. Default: codex on PATH.
  CODEX_MIND_MAINTAINER_HOME            Target home directory. Default: target user's home.
  CODEX_MIND_MAINTAINER_WORKSPACE       Codex working directory. Default: target home.
  CODEX_MIND_MAINTAINER_STATE_DIR       State/log/cache directory.
  CODEX_MIND_MAINTAINER_PROMPT_FILE     Prompt file. Default: ../prompt.md.
  CODEX_MIND_MAINTAINER_MODEL           Codex model. Default: gpt-5.5.
  CODEX_MIND_MAINTAINER_REASONING       Reasoning effort. Default: xhigh.
  CODEX_MIND_MAINTAINER_SANDBOX         Sandbox mode. Default: danger-full-access.
  CODEX_MIND_MAINTAINER_SHARED_AGENTS_URL
  CODEX_MIND_MAINTAINER_SHARED_NOTES_REPO_URL
  CODEX_MIND_MAINTAINER_SKILLS_REPO_URL
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
repo_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"
target_user="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"

if ! target_home="$(getent passwd "$target_user" | cut -d: -f6)"; then
  printf 'Unable to determine home directory for user: %s\n' "$target_user" >&2
  exit 1
fi

home_dir="${CODEX_MIND_MAINTAINER_HOME:-$target_home}"
workspace="${CODEX_MIND_MAINTAINER_WORKSPACE:-$home_dir}"
state_dir="${CODEX_MIND_MAINTAINER_STATE_DIR:-$home_dir/.local/state/codex-agent-mind-maintainer}"
prompt_file="${CODEX_MIND_MAINTAINER_PROMPT_FILE:-$repo_dir/prompt.md}"
codex_bin="${CODEX_BIN:-$(command -v codex || true)}"
model="${CODEX_MIND_MAINTAINER_MODEL:-gpt-5.5}"
reasoning="${CODEX_MIND_MAINTAINER_REASONING:-xhigh}"
sandbox="${CODEX_MIND_MAINTAINER_SANDBOX:-danger-full-access}"
shared_agents_url="${CODEX_MIND_MAINTAINER_SHARED_AGENTS_URL:-https://raw.githubusercontent.com/TheWorstProgrammerEver/Codex-Shared-Durable-Notes/main/AGENTS.shared.md}"
shared_notes_repo_url="${CODEX_MIND_MAINTAINER_SHARED_NOTES_REPO_URL:-https://github.com/TheWorstProgrammerEver/Codex-Shared-Durable-Notes.git}"
skills_repo_url="${CODEX_MIND_MAINTAINER_SKILLS_REPO_URL:-https://github.com/TheWorstProgrammerEver/codex-skills.git}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
logs_dir="$state_dir/logs"
cache_dir="$state_dir/cache"
review_dir="$state_dir/review"
last_run="$state_dir/last-run.md"
lock_file="$state_dir/run.lock"
log_file="$logs_dir/$run_id.log"

if [[ -z "$codex_bin" ]]; then
  printf 'Unable to find codex on PATH. Set CODEX_BIN explicitly.\n' >&2
  exit 1
fi

if [[ ! -f "$prompt_file" ]]; then
  printf 'Prompt file does not exist: %s\n' "$prompt_file" >&2
  exit 1
fi

if [[ ! -d "$workspace" ]]; then
  printf 'Workspace does not exist: %s\n' "$workspace" >&2
  exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
  printf 'flock is required to prevent overlapping runs.\n' >&2
  exit 1
fi

codex_args=(
  exec
  --model "$model"
  -c "model_reasoning_effort=\"$reasoning\""
  -c 'approval_policy="never"'
  --sandbox "$sandbox"
  --skip-git-repo-check
  --cd "$workspace"
  --output-last-message "__LAST_MESSAGE_PATH__"
)

if [[ "$dry_run" -eq 1 ]]; then
  printf 'Would start Codex Agent Mind Maintainer.\n'
  printf 'Home: %s\n' "$home_dir"
  printf 'Workspace: %s\n' "$workspace"
  printf 'State: %s\n' "$state_dir"
  printf 'Prompt: %s\n' "$prompt_file"
  printf 'Log: %s\n' "$log_file"
  printf 'Model: %s\n' "$model"
  printf 'Reasoning: %s\n' "$reasoning"
  printf 'Sandbox: %s\n' "$sandbox"
  printf 'Shared AGENTS URL: %s\n' "$shared_agents_url"
  printf 'Shared notes repo: %s\n' "$shared_notes_repo_url"
  printf 'Skills repo: %s\n' "$skills_repo_url"
  printf 'Command: %s' "$codex_bin"
  for arg in "${codex_args[@]}"; do
    printf ' %q' "$arg"
  done
  printf ' < %q\n' "$prompt_file"
  exit 0
fi

mkdir -p "$logs_dir" "$cache_dir" "$review_dir"

exec 9>"$lock_file"

if ! flock -n 9; then
  {
    printf '# Codex Agent Mind Maintainer Last Run\n\n'
    printf -- '- Run ID: %s\n' "$run_id"
    printf -- '- Started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- Status: skipped-overlap\n'
    printf -- '- Log: %s\n' "$log_file"
    printf '\nAnother maintainer run already holds the lock.\n'
  } >"$last_run"
  printf 'Another maintainer run is already active. Wrote %s\n' "$last_run"
  exit 0
fi

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
last_message="$(mktemp "$state_dir/last-message.XXXXXX.md")"
cleanup() {
  rm -f "$last_message"
}
trap cleanup EXIT

export CODEX_MIND_MAINTAINER_HOME="$home_dir"
export CODEX_MIND_MAINTAINER_WORKSPACE="$workspace"
export CODEX_MIND_MAINTAINER_STATE_DIR="$state_dir"
export CODEX_MIND_MAINTAINER_CACHE_DIR="$cache_dir"
export CODEX_MIND_MAINTAINER_REVIEW_DIR="$review_dir"
export CODEX_MIND_MAINTAINER_RUN_ID="$run_id"
export CODEX_MIND_MAINTAINER_RUN_LOG="$log_file"
export CODEX_MIND_MAINTAINER_LAST_RUN="$last_run"
export CODEX_MIND_MAINTAINER_SHARED_AGENTS_URL="$shared_agents_url"
export CODEX_MIND_MAINTAINER_SHARED_NOTES_REPO_URL="$shared_notes_repo_url"
export CODEX_MIND_MAINTAINER_SKILLS_REPO_URL="$skills_repo_url"

{
  printf '# Codex Agent Mind Maintainer Run\n\n'
  printf 'Run ID: %s\n' "$run_id"
  printf 'Started: %s\n' "$started_at"
  printf 'Home: %s\n' "$home_dir"
  printf 'Workspace: %s\n' "$workspace"
  printf 'State: %s\n' "$state_dir"
  printf 'Prompt: %s\n' "$prompt_file"
  printf 'Model: %s\n' "$model"
  printf 'Reasoning: %s\n' "$reasoning"
  printf 'Sandbox: %s\n' "$sandbox"
  printf '\n'
  printf '+ %q' "$codex_bin"
  for arg in "${codex_args[@]/__LAST_MESSAGE_PATH__/$last_message}"; do
    printf ' %q' "$arg"
  done
  printf ' < %q\n\n' "$prompt_file"
} >"$log_file"

set +e
"$codex_bin" "${codex_args[@]/__LAST_MESSAGE_PATH__/$last_message}" <"$prompt_file" >>"$log_file" 2>&1
exit_code=$?
set -e

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
status="succeeded"
if [[ "$exit_code" -ne 0 ]]; then
  status="failed"
fi

{
  printf '# Codex Agent Mind Maintainer Last Run\n\n'
  printf -- '- Run ID: %s\n' "$run_id"
  printf -- '- Started: %s\n' "$started_at"
  printf -- '- Finished: %s\n' "$finished_at"
  printf -- '- Status: %s\n' "$status"
  printf -- '- Exit code: %s\n' "$exit_code"
  printf -- '- Log: %s\n' "$log_file"
  printf -- '- Prompt: %s\n' "$prompt_file"
  printf -- '- Model: %s\n' "$model"
  printf -- '- Reasoning: %s\n' "$reasoning"
  printf -- '- Sandbox: %s\n' "$sandbox"
  printf '\n## Codex Final Message\n\n'
  if [[ -s "$last_message" ]]; then
    cat "$last_message"
    printf '\n'
  else
    printf 'No final message captured. Inspect the run log.\n'
  fi
} >"$last_run"

printf 'Mind Maintainer %s. Summary: %s\n' "$status" "$last_run"
printf 'Log: %s\n' "$log_file"

exit "$exit_code"
