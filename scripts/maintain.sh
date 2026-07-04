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
  CODEX_MIND_MAINTAINER_PREFLIGHT_SCRIPT
                                         Preflight script. Default: ./scripts/preflight.mjs.
  CODEX_MIND_MAINTAINER_PREFLIGHT       Set 0 to bypass preflight.
  CODEX_MIND_MAINTAINER_FORCE_FULL      Set 1 to force full maintenance.
  CODEX_MIND_MAINTAINER_POLICY_VERSION  Reconciliation policy version.
  CODEX_MIND_MAINTAINER_MODEL           Codex model. Default: gpt-5.5.
  CODEX_MIND_MAINTAINER_REASONING       Reasoning effort. Default: xhigh.
  CODEX_MIND_MAINTAINER_SANDBOX         Sandbox mode. Default: danger-full-access.
  CODEX_MIND_MAINTAINER_LOG_RETENTION_DAYS
                                         Delete old logs after this many days. Default: 90. Set 0 to disable.
  CODEX_MIND_MAINTAINER_MIN_LOGS_TO_KEEP
                                         Keep at least this many logs. Default: 20.
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
preflight_script="${CODEX_MIND_MAINTAINER_PREFLIGHT_SCRIPT:-$repo_dir/scripts/preflight.mjs}"
preflight_enabled="${CODEX_MIND_MAINTAINER_PREFLIGHT:-1}"
codex_bin="${CODEX_BIN:-$(command -v codex || true)}"
model="${CODEX_MIND_MAINTAINER_MODEL:-gpt-5.5}"
reasoning="${CODEX_MIND_MAINTAINER_REASONING:-xhigh}"
sandbox="${CODEX_MIND_MAINTAINER_SANDBOX:-danger-full-access}"
log_retention_days="${CODEX_MIND_MAINTAINER_LOG_RETENTION_DAYS:-90}"
min_logs_to_keep="${CODEX_MIND_MAINTAINER_MIN_LOGS_TO_KEEP:-20}"
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

if [[ ! -f "$prompt_file" ]]; then
  printf 'Prompt file does not exist: %s\n' "$prompt_file" >&2
  exit 1
fi

if [[ ! -d "$workspace" ]]; then
  printf 'Workspace does not exist: %s\n' "$workspace" >&2
  exit 1
fi

if [[ "$preflight_enabled" != "0" && ! -f "$preflight_script" ]]; then
  printf 'Preflight script does not exist: %s\n' "$preflight_script" >&2
  exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
  printf 'flock is required to prevent overlapping runs.\n' >&2
  exit 1
fi

if [[ "$preflight_enabled" != "0" ]] && ! command -v node >/dev/null 2>&1; then
  printf 'node is required for deterministic preflight.\n' >&2
  exit 1
fi

if [[ ! "$log_retention_days" =~ ^[0-9]+$ ]]; then
  printf 'CODEX_MIND_MAINTAINER_LOG_RETENTION_DAYS must be a non-negative integer.\n' >&2
  exit 1
fi

if [[ ! "$min_logs_to_keep" =~ ^[0-9]+$ ]]; then
  printf 'CODEX_MIND_MAINTAINER_MIN_LOGS_TO_KEEP must be a non-negative integer.\n' >&2
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
  printf 'Preflight: %s\n' "$preflight_script"
  printf 'Preflight enabled: %s\n' "$preflight_enabled"
  printf 'Log: %s\n' "$log_file"
  printf 'Model: %s\n' "$model"
  printf 'Reasoning: %s\n' "$reasoning"
  printf 'Sandbox: %s\n' "$sandbox"
  printf 'Log retention days: %s\n' "$log_retention_days"
  printf 'Minimum logs to keep: %s\n' "$min_logs_to_keep"
  printf 'Shared AGENTS URL: %s\n' "$shared_agents_url"
  printf 'Shared notes repo: %s\n' "$shared_notes_repo_url"
  printf 'Skills repo: %s\n' "$skills_repo_url"
  if [[ -n "$codex_bin" ]]; then
    printf 'Command: %s' "$codex_bin"
    for arg in "${codex_args[@]}"; do
      printf ' %q' "$arg"
    done
    printf ' < %q\n' "$prompt_file"
  else
    printf 'Command: codex not found; no-op preflight runs do not require it.\n'
  fi
  exit 0
fi

mkdir -p "$logs_dir" "$cache_dir" "$review_dir"

prune_old_logs() {
  if [[ "$log_retention_days" == "0" ]]; then
    return
  fi

  local deleted=0
  local seen=0
  local entry
  local log_path
  local old_match
  local log_entries=()

  mapfile -d '' log_entries < <(
    find "$logs_dir" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\0' |
      sort -z -nr
  )

  for entry in "${log_entries[@]}"; do
    log_path="${entry#* }"
    ((seen += 1))

    if ((seen <= min_logs_to_keep)); then
      continue
    fi

    old_match="$(find "$log_path" -maxdepth 0 -type f -mtime +"$log_retention_days" -print -quit)"
    if [[ -n "$old_match" ]]; then
      rm -f -- "$log_path"
      ((deleted += 1))
    fi
  done

  if ((deleted > 0)); then
    printf 'Pruned %s old maintainer log(s); retention=%sd min-keep=%s.\n' \
      "$deleted" "$log_retention_days" "$min_logs_to_keep" | tee -a "$log_file"
  fi
}

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
prompt_input=""
cleanup() {
  rm -f "$last_message"
  if [[ -n "$prompt_input" && "$prompt_input" == "$state_dir"/prompt-input.*.md ]]; then
    rm -f "$prompt_input"
  fi
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
export CODEX_MIND_MAINTAINER_MODEL="$model"
export CODEX_MIND_MAINTAINER_REASONING="$reasoning"

{
  printf '# Codex Agent Mind Maintainer Run\n\n'
  printf 'Run ID: %s\n' "$run_id"
  printf 'Started: %s\n' "$started_at"
  printf 'Home: %s\n' "$home_dir"
  printf 'Workspace: %s\n' "$workspace"
  printf 'State: %s\n' "$state_dir"
  printf 'Prompt: %s\n' "$prompt_file"
  printf 'Preflight: %s\n' "$preflight_script"
  printf 'Preflight enabled: %s\n' "$preflight_enabled"
  printf 'Model: %s\n' "$model"
  printf 'Reasoning: %s\n' "$reasoning"
  printf 'Sandbox: %s\n' "$sandbox"
  printf 'Log retention days: %s\n' "$log_retention_days"
  printf 'Minimum logs to keep: %s\n' "$min_logs_to_keep"
  printf '\n'
} | tee "$log_file"

preflight_status="preflight-worklist"
preflight_summary="Preflight bypassed."
preflight_result=""
preflight_worklist=""
preflight_exit_code=0

if [[ "$preflight_enabled" == "0" ]]; then
  preflight_worklist=""
else
  printf '+ node %q\n\n' "$preflight_script" | tee -a "$log_file"
  set +e
  node "$preflight_script" 2>&1 | tee -a "$log_file"
  preflight_exit_code=${PIPESTATUS[0]}
  set -e

  preflight_result="$state_dir/preflight/$run_id-result.json"
  if [[ "$preflight_exit_code" -ne 0 ]]; then
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
      printf '# Codex Agent Mind Maintainer Last Run\n\n'
      printf -- '- Run ID: %s\n' "$run_id"
      printf -- '- Started: %s\n' "$started_at"
      printf -- '- Finished: %s\n' "$finished_at"
      printf -- '- Status: preflight-failed\n'
      printf -- '- Exit code: %s\n' "$preflight_exit_code"
      printf -- '- Log: %s\n' "$log_file"
      printf -- '- Preflight result: %s\n' "$preflight_result"
      printf '\nPreflight failed before full Codex maintenance. Inspect the log and result JSON.\n'
    } >"$last_run"
    prune_old_logs
    printf 'Mind Maintainer preflight failed. Summary: %s\n' "$last_run"
    printf 'Log: %s\n' "$log_file"
    exit "$preflight_exit_code"
  fi

  preflight_status="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).status)' "$preflight_result")"
  preflight_summary="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).summary)' "$preflight_result")"
  preflight_worklist="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).worklistPath || "")' "$preflight_result")"
  export CODEX_MIND_MAINTAINER_PREFLIGHT_RESULT="$preflight_result"
  export CODEX_MIND_MAINTAINER_PREFLIGHT_WORKLIST="$preflight_worklist"

  if [[ "$preflight_status" == "preflight-noop" ]]; then
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
      printf '# Codex Agent Mind Maintainer Last Run\n\n'
      printf -- '- Run ID: %s\n' "$run_id"
      printf -- '- Started: %s\n' "$started_at"
      printf -- '- Finished: %s\n' "$finished_at"
      printf -- '- Status: preflight-noop\n'
      printf -- '- Exit code: 0\n'
      printf -- '- Log: %s\n' "$log_file"
      printf -- '- Preflight result: %s\n' "$preflight_result"
      printf '\n%s\n' "$preflight_summary"
    } >"$last_run"
    prune_old_logs
    printf 'Mind Maintainer preflight-noop. Summary: %s\n' "$last_run"
    printf 'Log: %s\n' "$log_file"
    exit 0
  fi
fi

if [[ -z "$codex_bin" ]]; then
  printf 'Unable to find codex on PATH. Set CODEX_BIN explicitly.\n' >&2 | tee -a "$log_file"
  exit 1
fi

if [[ -n "$preflight_worklist" ]]; then
  prompt_input="$(mktemp "$state_dir/prompt-input.XXXXXX.md")"
  {
    cat "$prompt_file"
    printf '\n\n## Deterministic Preflight Worklist\n\n'
    cat "$preflight_worklist"
  } >"$prompt_input"
else
  prompt_input="$prompt_file"
fi

{
  printf '\nPreflight status: %s\n' "$preflight_status"
  printf 'Preflight summary: %s\n' "$preflight_summary"
  if [[ -n "$preflight_result" ]]; then
    printf 'Preflight result: %s\n' "$preflight_result"
  fi
  if [[ -n "$preflight_worklist" ]]; then
    printf 'Preflight worklist: %s\n' "$preflight_worklist"
  fi
  printf '\n'
  printf '+ %q' "$codex_bin"
  for arg in "${codex_args[@]/__LAST_MESSAGE_PATH__/$last_message}"; do
    printf ' %q' "$arg"
  done
  printf ' < %q\n\n' "$prompt_input"
} | tee -a "$log_file"

set +e
"$codex_bin" "${codex_args[@]/__LAST_MESSAGE_PATH__/$last_message}" <"$prompt_input" 2>&1 |
  tee -a "$log_file"
exit_code=${PIPESTATUS[0]}
set -e

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
status="full-maintenance-succeeded"
if [[ "$exit_code" -ne 0 ]]; then
  status="full-maintenance-failed"
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
  printf -- '- Preflight status: %s\n' "$preflight_status"
  printf -- '- Preflight summary: %s\n' "$preflight_summary"
  if [[ -n "$preflight_result" ]]; then
    printf -- '- Preflight result: %s\n' "$preflight_result"
  fi
  if [[ -n "$preflight_worklist" ]]; then
    printf -- '- Preflight worklist: %s\n' "$preflight_worklist"
  fi
  printf -- '- Model: %s\n' "$model"
  printf -- '- Reasoning: %s\n' "$reasoning"
  printf -- '- Sandbox: %s\n' "$sandbox"
  printf -- '- Log retention days: %s\n' "$log_retention_days"
  printf -- '- Minimum logs to keep: %s\n' "$min_logs_to_keep"
  printf '\n## Codex Final Message\n\n'
  if [[ -s "$last_message" ]]; then
    cat "$last_message"
    printf '\n'
  else
    printf 'No final message captured. Inspect the run log.\n'
  fi
} >"$last_run"

prune_old_logs

printf 'Mind Maintainer %s. Summary: %s\n' "$status" "$last_run"
printf 'Log: %s\n' "$log_file"

exit "$exit_code"
