# Codex Agent Mind Maintainer

Host-native scheduled maintenance for a dedicated Codex agent host.

The maintainer starts a fresh `codex exec` run on a schedule. The shell scripts
own scheduling, locking, logs, and last-run summaries. The main maintenance
policy lives in the single prompt file at `prompt.md`.

## What It Does

Each run asks Codex to:

- refresh the managed shared guidance block in the local `AGENTS.md`;
- merge useful shared durable notes without overwriting local host state;
- install or update shared Codex skills;
- record a concise self-check covering changes, skipped work, and human review.

The default shared sources are:

- `https://github.com/TheWorstProgrammerEver/Codex-Shared-Durable-Notes`
- `https://github.com/TheWorstProgrammerEver/codex-skills`
- `https://raw.githubusercontent.com/TheWorstProgrammerEver/Codex-Shared-Durable-Notes/main/AGENTS.shared.md`

## Safety Model

- Local `AGENTS.md` content outside the managed block is preserved.
- Local durable notes are never overwritten wholesale.
- Existing local notes win when a shared note merge is ambiguous.
- Secrets, private keys, tokens, passwords, Wi-Fi credentials, OAuth material,
  local-only credential values, host-only facts, device identifiers, and private
  paths must not be copied into shared intelligence or committed.
- Ambiguous shared guidance, durable-note, or skill changes should become a
  Linear Backlog issue rather than an autonomous risky edit.
- Overlapping runs are blocked by both the systemd service lifecycle and an
  explicit `flock` lock in `scripts/maintain.sh`.

## Manual Run

Preview the command without starting Codex:

```sh
./scripts/maintain.sh --dry-run
```

Run the maintainer once:

```sh
./scripts/maintain.sh
```

By default this invokes:

- model: `gpt-5.5`
- reasoning: `xhigh`
- sandbox: `danger-full-access`
- working directory: the target user's home directory

Override with environment variables:

```sh
CODEX_MIND_MAINTAINER_MODEL=gpt-5.5 \
CODEX_MIND_MAINTAINER_REASONING=xhigh \
CODEX_MIND_MAINTAINER_WORKSPACE="$HOME" \
./scripts/maintain.sh
```

## Install Schedule

Preview the systemd units:

```sh
./scripts/install-schedule.sh --dry-run
```

Install the timer into `/etc/systemd/system`:

```sh
sudo ./scripts/install-schedule.sh
```

The default schedule is every 6 hours:

```sh
SCHEDULE_INTERVAL=6h
```

Change it at install time:

```sh
sudo SCHEDULE_INTERVAL=3h ./scripts/install-schedule.sh
```

The installer writes:

- `codex-agent-mind-maintainer.service`
- `codex-agent-mind-maintainer.timer`

The service also reads an optional environment file:

```text
~/.config/codex-agent-mind-maintainer/env
```

Use that file for non-secret configuration such as model, schedule sources, or
state directory overrides. Do not store credentials or tokens there.

## Uninstall Schedule

Preview removal:

```sh
./scripts/uninstall-schedule.sh --dry-run
```

Remove installed units:

```sh
sudo ./scripts/uninstall-schedule.sh
```

Uninstalling the timer does not delete local durable notes, installed skills, or
maintainer logs.

## Status And Logs

Show timer status, recent runs, and the last-run summary:

```sh
./scripts/status.sh
```

Default state location:

```text
~/.local/state/codex-agent-mind-maintainer
```

Important files:

- `last-run.md` - latest run summary and Codex final message.
- `logs/` - stdout/stderr logs for each maintainer run.
- `cache/` - shared repo clones or other temporary working copies used by Codex.
- `review/` - candidate files or notes that need human review.

Codex output is streamed through systemd/journald and appended to the per-run
log file. This keeps live inspection simple while preserving durable run logs.

Log retention defaults:

- `CODEX_MIND_MAINTAINER_LOG_RETENTION_DAYS=90`
- `CODEX_MIND_MAINTAINER_MIN_LOGS_TO_KEEP=20`

Set `CODEX_MIND_MAINTAINER_LOG_RETENTION_DAYS=0` to disable pruning. Retention
only applies to `logs/*.log`; it does not delete `last-run.md`, `review/`, or
cached shared repositories.

Systemd inspection:

```sh
systemctl status codex-agent-mind-maintainer.timer
systemctl status codex-agent-mind-maintainer.service
journalctl -u codex-agent-mind-maintainer.service -n 200
systemctl list-timers codex-agent-mind-maintainer.timer
```

## Rollback

1. Stop the timer with `sudo ./scripts/uninstall-schedule.sh`.
2. Inspect `last-run.md` and the referenced log.
3. Revert only the local files that need rollback. Start with:
   - `~/AGENTS.md`
   - `~/codex-notes/`
   - `~/.codex/skills/`
4. Keep any useful audit context in durable notes, without storing secrets.

The maintainer prompt tells Codex to prefer backups, readable diffs, and review
artifacts for risky durable-note merges.

## Validation

Useful checks before installing or after edits:

```sh
bash -n scripts/*.sh
./scripts/test.sh
./scripts/maintain.sh --dry-run
./scripts/install-schedule.sh --dry-run
./scripts/uninstall-schedule.sh --dry-run
```

If `systemd-analyze` is installed, the installer dry-run also verifies the
generated unit files.
