#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";
import {
  extractManagedBlock,
  gitFiles,
  hashFile,
  hashText,
  readLedger,
  readSharedAgents,
  renderWorklist,
  requiredEnv,
  skillWorkItems,
  truthy,
  updateGitCache,
  writeJson,
} from "./preflight-support.mjs";

const schemaVersion = 1;
const policyVersion = process.env.CODEX_MIND_MAINTAINER_POLICY_VERSION ?? "2026-07-05-preflight-v1";
const sourceIssue = process.env.CODEX_MIND_MAINTAINER_SOURCE_ISSUE ?? "RYA-25";
const forceFull = truthy(process.env.CODEX_MIND_MAINTAINER_FORCE_FULL);
const runId = requiredEnv("CODEX_MIND_MAINTAINER_RUN_ID");
const homeDir = requiredEnv("CODEX_MIND_MAINTAINER_HOME");
const stateDir = requiredEnv("CODEX_MIND_MAINTAINER_STATE_DIR");
const cacheDir = requiredEnv("CODEX_MIND_MAINTAINER_CACHE_DIR");
const model = process.env.CODEX_MIND_MAINTAINER_MODEL ?? null;
const reasoningLabel = process.env.CODEX_MIND_MAINTAINER_REASONING ?? null;
const agentId = process.env.CODEX_MIND_MAINTAINER_AGENT_ID ?? null;
const sharedAgentsUrl = requiredEnv("CODEX_MIND_MAINTAINER_SHARED_AGENTS_URL");
const sharedNotesRepoUrl = requiredEnv("CODEX_MIND_MAINTAINER_SHARED_NOTES_REPO_URL");
const skillsRepoUrl = requiredEnv("CODEX_MIND_MAINTAINER_SKILLS_REPO_URL");

const preflightDir = join(stateDir, "preflight");
const ledgerPath = join(stateDir, "reconciliation-ledger.jsonl");
const resultPath = join(preflightDir, `${runId}-result.json`);
const worklistPath = join(preflightDir, `${runId}-worklist.md`);
const sharedNotesCache = join(cacheDir, "shared-durable-notes");
const skillsCache = join(cacheDir, "codex-skills");
const defaultSharedAgentsUrl =
  "https://raw.githubusercontent.com/TheWorstProgrammerEver/Codex-Shared-Durable-Notes/main/AGENTS.shared.md";
const finalDurableNoteDecisions = ["local-authoritative", "merged"];
const unresolvedDurableNoteDecisions = ["needs-human-review", "preflight-worklist"];

mkdirSync(preflightDir, { recursive: true });

try {
  const result = runPreflight();
  writeJson(resultPath, result);
  if (result.worklist.length > 0) {
    writeFileSync(worklistPath, renderWorklist(result), "utf8");
  }
  appendLedger({
    eventType: "preflight-summary",
    target: "preflight",
    path: null,
    decision: result.status,
    rationale: result.summary,
    worklistCount: result.worklist.length,
    skippedKnownConflictCount: result.skippedKnownConflictCount,
    recheck: result.status === "preflight-noop" ? "manual" : "next-run",
  });
  console.log(JSON.stringify(result));
} catch (error) {
  const result = {
    schemaVersion,
    runId,
    status: "preflight-failed",
    summary: error instanceof Error ? error.message : String(error),
    resultPath,
    worklistPath: null,
    ledgerPath,
    worklist: [],
    skippedKnownConflictCount: 0,
  };
  writeJson(resultPath, result);
  appendLedger({
    eventType: "preflight-summary",
    target: "preflight",
    path: null,
    decision: "preflight-failed",
    rationale: result.summary,
    worklistCount: 0,
    skippedKnownConflictCount: 0,
    recheck: "next-run",
  });
  console.error(result.summary);
  process.exit(1);
}

function runPreflight() {
  const ledger = readLedger(ledgerPath);
  const sharedNotesRef = updateGitCache(sharedNotesCache, sharedNotesRepoUrl);
  const skillsRef = updateGitCache(skillsCache, skillsRepoUrl);
  const sharedAgentsContent = readSharedAgents(sharedNotesCache, sharedAgentsUrl, defaultSharedAgentsUrl);
  const sharedAgentsHash = hashText(sharedAgentsContent);
  const sharedAgentsBlockHash = hashText(extractManagedBlock(sharedAgentsContent));
  const localAgentsPath = join(homeDir, "AGENTS.md");
  const localAgentsHash = existsSync(localAgentsPath)
    ? hashText(extractManagedBlock(readFileSync(localAgentsPath, "utf8")))
    : null;
  const worklist = [];
  const ledgerEvents = [];
  let skippedKnownConflictCount = 0;

  if (forceFull) {
    worklist.push(workItem({
      target: "manual-recheck",
      path: null,
      reason: "Manual full maintenance requested by CODEX_MIND_MAINTAINER_FORCE_FULL.",
      sharedRef: sharedNotesRef,
      sharedHash: sharedAgentsHash,
      localHash: null,
      mergePolicy: "manual-review",
      authority: "linear",
      scope: "generated",
    }));
  }

  if (localAgentsHash !== sharedAgentsBlockHash) {
    worklist.push(workItem({
      target: "agents-managed-block",
      path: "AGENTS.md",
      reason: localAgentsHash === null
        ? "Local AGENTS.md is missing; the shared managed block should be inserted while preserving local content."
        : "Local AGENTS.md managed block does not match shared guidance.",
      sharedRef: sharedNotesRef,
      sharedHash: sharedAgentsBlockHash,
      localHash: localAgentsHash,
      mergePolicy: "managed-block",
      authority: "shared",
      scope: "local",
    }));
  }

  for (const file of gitFiles(sharedNotesCache)) {
    if (file === "AGENTS.shared.md" || file.startsWith(".github/")) {
      continue;
    }
    const sharedPath = join(sharedNotesCache, file);
    const localPath = join(homeDir, "codex-notes", file);
    const sharedHash = hashFile(sharedPath);
    const localHash = existsSync(localPath) ? hashFile(localPath) : null;

    if (localHash === sharedHash) {
      continue;
    }

    const prior = latestPathEvent(ledger, file);
    const hashes = { sharedHash, localHash };

    if (isUnresolvedDecision(prior)) {
      worklist.push(workItem({
        target: "durable-note-unresolved",
        path: file,
        reason: "Prior ledger decision is unresolved and must remain in the focused worklist.",
        sharedRef: sharedNotesRef,
        sharedHash,
        localHash,
        mergePolicy: "manual-review",
        authority: "local",
        scope: "local",
      }));
      continue;
    }

    if (isKnownLocalAuthoritative(file) && localHash !== null) {
      if (!prior) {
        ledgerEvents.push(localAuthoritativeEvent(file, sharedNotesRef, sharedHash, localHash));
        skippedKnownConflictCount += 1;
        continue;
      }

      if (isCurrentDecision(prior, hashes, finalDurableNoteDecisions)) {
        skippedKnownConflictCount += 1;
        continue;
      }

      worklist.push(workItem({
        target: "durable-note-conflict",
        path: file,
        reason: "Known local-authoritative note changed shared hash, policy, or recheck state and needs re-evaluation.",
        sharedRef: sharedNotesRef,
        sharedHash,
        localHash,
        mergePolicy: "local-authoritative",
        authority: "local",
        scope: "local",
      }));
      continue;
    }

    if (isCurrentDecision(prior, hashes, finalDurableNoteDecisions)) {
      skippedKnownConflictCount += 1;
      continue;
    }

    worklist.push(workItem({
      target: localHash === null ? "durable-note-missing" : "durable-note-conflict",
      path: file,
      reason: localHash === null
        ? "Shared durable note has no local counterpart."
        : "Shared durable note differs from the local note and is not configured as a deterministic local-authoritative skip.",
      sharedRef: sharedNotesRef,
      sharedHash,
      localHash,
      mergePolicy: localHash === null ? "shared-owned" : "manual-review",
      authority: localHash === null ? "shared" : "local",
      scope: "local",
    }));
  }

  const skillItems = skillWorkItems(skillsCache, skillsRef, homeDir, workItem);
  worklist.push(...skillItems);

  for (const event of ledgerEvents) {
    appendLedger(event);
  }

  for (const item of worklist) {
    appendLedger({
      eventType: "reconciliation-decision",
      target: item.target,
      path: item.path,
      sharedRef: item.sharedRef,
      sharedHash: item.sharedHash,
      localHash: item.localHash,
      scope: item.scope,
      authority: item.authority,
      mergePolicy: item.mergePolicy,
      decision: "preflight-worklist",
      rationale: item.reason,
      recheck: "next-run",
    });
  }

  const status = worklist.length === 0 ? "preflight-noop" : "preflight-worklist";
  const summary = status === "preflight-noop"
    ? `Preflight found no unreconciled changes; ${skippedKnownConflictCount} reconciled durable-note conflict(s) skipped by reconciliation ledger.`
    : `Preflight found ${worklist.length} unreconciled item(s); full maintenance should use the focused worklist.`;

  return {
    schemaVersion,
    runId,
    status,
    summary,
    policyVersion,
    sourceIssue,
    sharedNotesRef,
    skillsRef,
    resultPath,
    worklistPath: worklist.length === 0 ? null : worklistPath,
    ledgerPath,
    skippedKnownConflictCount,
    worklist,
  };
}

function isKnownLocalAuthoritative(path) {
  return path === "INDEX.md" ||
    path === "credentials/NOTES.md" ||
    path === "state/HOST.md" ||
    path === "state/CURRENT.md" ||
    path.startsWith("tasks/") ||
    path.startsWith("ledger/") ||
    path.startsWith("runbooks/") ||
    path.startsWith("projects/");
}

function latestPathEvent(events, path) {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    if (events[index]?.path === path && events[index]?.eventType === "reconciliation-decision") {
      return events[index];
    }
  }
  return null;
}

function isUnresolvedDecision(event) {
  return unresolvedDurableNoteDecisions.includes(event?.decision);
}

function isCurrentDecision(event, target, acceptedDecisions) {
  if (!event) {
    return false;
  }
  if (!acceptedDecisions.includes(event.decision)) {
    return false;
  }
  if (event.policyVersion !== policyVersion) {
    return false;
  }
  if (forceFull) {
    return false;
  }
  const recheck = event.recheck ?? "shared-hash-change";
  if (recheck.includes("shared-hash") && event.sharedHash !== target.sharedHash) {
    return false;
  }
  if (recheck.includes("local-hash") && event.localHash !== target.localHash) {
    return false;
  }
  if (recheck.startsWith("ttl:") && ttlExpired(event.timestamp, recheck.slice(4))) {
    return false;
  }
  return true;
}

function ttlExpired(timestamp, duration) {
  const match = duration.match(/^P?(\d+)D$/);
  if (!match || !timestamp) {
    return true;
  }
  const createdAt = Date.parse(timestamp);
  if (!Number.isFinite(createdAt)) {
    return true;
  }
  return Date.now() - createdAt > Number(match[1]) * 24 * 60 * 60 * 1000;
}

function localAuthoritativeEvent(path, sharedRef, sharedHash, localHash) {
  return {
    eventType: "reconciliation-decision",
    target: "durable-note-conflict",
    path,
    sharedRef,
    sharedHash,
    localHash,
    scope: "local",
    authority: "local",
    mergePolicy: "local-authoritative",
    decision: "local-authoritative",
    rationale: "Configured local-authoritative durable note; preserve local host/task context and skip unchanged recurring conflict.",
    recheck: "shared-hash-change",
  };
}

function workItem({ target, path, reason, sharedRef, sharedHash, localHash, mergePolicy, authority, scope }) {
  return { target, path, reason, sharedRef, sharedHash, localHash, mergePolicy, authority, scope };
}

function appendLedger(event) {
  const complete = {
    schemaVersion,
    timestamp: new Date().toISOString(),
    agentId,
    runId,
    model,
    reasoningLabel,
    policyVersion,
    sourceIssue,
    ...event,
  };
  appendFileSync(ledgerPath, `${JSON.stringify(complete)}\n`, "utf8");
}
