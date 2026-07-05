#!/usr/bin/env node
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, cpSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";

const repoDir = new URL("..", import.meta.url).pathname;
const preflightScript = join(repoDir, "scripts", "preflight.mjs");
const tmpRoot = mkdtempSync(join(tmpdir(), "mind-maintainer-preflight-test-"));

try {
  testNoopAndKnownConflicts();
  testChangedSharedHash();
  testChangedPolicyVersion();
  testManualFinalDecisionForNonBuiltInPaths();
  testUnresolvedPriorDecision();
  testFailedFetch();
  console.log("preflight tests passed");
} finally {
  rmSync(tmpRoot, { recursive: true, force: true });
}

function testNoopAndKnownConflicts() {
  const fixture = createFixture("noop-known-conflicts");
  const first = runPreflight(fixture, "20260705T000001Z");
  assert.equal(first.status, "preflight-noop");
  assert.equal(first.skippedKnownConflictCount, 2);
  assert.equal(first.worklist.length, 0);

  const second = runPreflight(fixture, "20260705T000002Z");
  assert.equal(second.status, "preflight-noop");
  assert.equal(second.skippedKnownConflictCount, 2);

  const ledger = readLedger(fixture.stateDir);
  assert.equal(ledger.filter((event) => event.decision === "local-authoritative").length, 2);
}

function testChangedSharedHash() {
  const fixture = createFixture("changed-shared-hash");
  runPreflight(fixture, "20260705T000003Z");
  writeFileSync(join(fixture.sharedNotesRepo, "state", "HOST.md"), "# Shared Host Template\n\nChanged.\n");
  git(fixture.sharedNotesRepo, ["add", "."]);
  git(fixture.sharedNotesRepo, ["commit", "-m", "Change shared host template"]);

  const result = runPreflight(fixture, "20260705T000004Z");
  assert.equal(result.status, "preflight-worklist");
  assert.ok(result.worklist.some((item) => item.path === "state/HOST.md"));
}

function testChangedPolicyVersion() {
  const fixture = createFixture("changed-policy-version");
  runPreflight(fixture, "20260705T000005Z");
  const result = runPreflight(fixture, "20260705T000006Z", {
    CODEX_MIND_MAINTAINER_POLICY_VERSION: "2026-07-05-preflight-v2",
  });
  assert.equal(result.status, "preflight-worklist");
  assert.ok(result.worklist.some((item) => item.path === "state/HOST.md"));
}

function testManualFinalDecisionForNonBuiltInPaths() {
  const fixture = createFixture("manual-final-decision-non-built-in", {
    sharedFiles: {
      "decisions/example.md": "# Shared Decision\n",
      "preferences/README.md": "# Shared Preferences\n",
    },
    localFiles: {
      "decisions/example.md": "# Local Decision\n",
      "preferences/README.md": "# Local Preferences\n",
    },
  });
  const first = runPreflight(fixture, "20260705T000007Z");
  assert.equal(first.status, "preflight-worklist");
  const decisionItem = workItemForPath(first, "decisions/example.md");
  const preferencesItem = workItemForPath(first, "preferences/README.md");

  appendDecision(fixture.stateDir, {
    runId: "20260705T000007Z",
    decision: "local-authoritative",
    recheck: "shared-hash-change local-hash-change",
    item: decisionItem,
  });
  appendDecision(fixture.stateDir, {
    runId: "20260705T000007Z",
    decision: "merged",
    recheck: "shared-hash-change local-hash-change",
    item: preferencesItem,
  });

  const second = runPreflight(fixture, "20260705T000008Z");
  assert.equal(second.status, "preflight-noop");
  assert.equal(second.worklist.length, 0);
  assert.equal(second.skippedKnownConflictCount, 4);

  writeFileSync(join(fixture.homeDir, "codex-notes", "preferences", "README.md"), "# Changed Local Preferences\n");
  const third = runPreflight(fixture, "20260705T000009Z");
  assert.equal(third.status, "preflight-worklist");
  assert.ok(third.worklist.some((item) => item.path === "preferences/README.md"));
}

function testUnresolvedPriorDecision() {
  const fixture = createFixture("unresolved-prior-decision", {
    sharedFiles: {
      "notes/UNKNOWN.md": "# Shared\n",
    },
    localFiles: {
      "notes/UNKNOWN.md": "# Local\n",
    },
  });
  const first = runPreflight(fixture, "20260705T000010Z");
  assert.equal(first.status, "preflight-worklist");
  assert.ok(first.worklist.some((item) => item.path === "notes/UNKNOWN.md"));

  const second = runPreflight(fixture, "20260705T000011Z");
  assert.equal(second.status, "preflight-worklist");
  assert.ok(second.worklist.some((item) => item.target === "durable-note-unresolved"));
}

function testFailedFetch() {
  const fixture = createFixture("failed-fetch");
  const result = spawnSync("node", [preflightScript], {
    encoding: "utf8",
    env: {
      ...process.env,
      CODEX_MIND_MAINTAINER_RUN_ID: "20260705T000012Z",
      CODEX_MIND_MAINTAINER_HOME: fixture.homeDir,
      CODEX_MIND_MAINTAINER_STATE_DIR: fixture.stateDir,
      CODEX_MIND_MAINTAINER_CACHE_DIR: fixture.cacheDir,
      CODEX_MIND_MAINTAINER_SHARED_AGENTS_URL: fixture.sharedAgentsFile,
      CODEX_MIND_MAINTAINER_SHARED_NOTES_REPO_URL: join(fixture.root, "missing-notes-repo"),
      CODEX_MIND_MAINTAINER_SKILLS_REPO_URL: fixture.skillsRepo,
    },
  });
  assert.notEqual(result.status, 0);
  const saved = JSON.parse(readFileSync(join(fixture.stateDir, "preflight", "20260705T000012Z-result.json"), "utf8"));
  assert.equal(saved.status, "preflight-failed");
}

function createFixture(name, overrides = {}) {
  const root = join(tmpRoot, name);
  const homeDir = join(root, "home");
  const stateDir = join(root, "state");
  const cacheDir = join(stateDir, "cache");
  const sharedNotesRepo = join(root, "shared-notes");
  const skillsRepo = join(root, "skills");
  const sharedAgentsFile = join(sharedNotesRepo, "AGENTS.shared.md");
  mkdirSync(homeDir, { recursive: true });
  mkdirSync(join(homeDir, "codex-notes", "state"), { recursive: true });
  mkdirSync(join(homeDir, ".codex", "skills"), { recursive: true });
  mkdirSync(sharedNotesRepo, { recursive: true });
  mkdirSync(join(sharedNotesRepo, "state"), { recursive: true });
  mkdirSync(skillsRepo, { recursive: true });

  const sharedBlock = [
    "# Shared Agents",
    "",
    "<!-- BEGIN SHARED_AGENT_GUIDANCE -->",
    "- Shared guidance.",
    "<!-- END SHARED_AGENT_GUIDANCE -->",
    "",
  ].join("\n");
  writeFileSync(sharedAgentsFile, sharedBlock);
  writeFileSync(join(sharedNotesRepo, "INDEX.md"), "# Shared Index\n");
  writeFileSync(join(sharedNotesRepo, "state", "HOST.md"), "# Shared Host Template\n");
  writeFileSync(join(sharedNotesRepo, "state", "CURRENT.md"), "# Shared Current Template\n");
  for (const [path, content] of Object.entries(overrides.sharedFiles ?? {})) {
    writeFile(join(sharedNotesRepo, path), content);
  }
  initGit(sharedNotesRepo);

  writeFileSync(join(homeDir, "AGENTS.md"), [
    "# Local Agents",
    "",
    "<!-- BEGIN SHARED_AGENT_GUIDANCE -->",
    "- Shared guidance.",
    "<!-- END SHARED_AGENT_GUIDANCE -->",
    "",
    "- Local guidance.",
    "",
  ].join("\n"));
  writeFileSync(join(homeDir, "codex-notes", "INDEX.md"), "# Local Index\n");
  writeFileSync(join(homeDir, "codex-notes", "state", "HOST.md"), "# Local Host\n");
  writeFileSync(join(homeDir, "codex-notes", "state", "CURRENT.md"), "# Shared Current Template\n");
  for (const [path, content] of Object.entries(overrides.localFiles ?? {})) {
    writeFile(join(homeDir, "codex-notes", path), content);
  }

  mkdirSync(join(skillsRepo, "example-skill"), { recursive: true });
  writeFileSync(join(skillsRepo, "example-skill", "SKILL.md"), "# Example Skill\n");
  writeFileSync(join(skillsRepo, "README.md"), "# Skills\n");
  initGit(skillsRepo);
  cpSync(join(skillsRepo, "example-skill"), join(homeDir, ".codex", "skills", "example-skill"), { recursive: true });

  return { root, homeDir, stateDir, cacheDir, sharedNotesRepo, skillsRepo, sharedAgentsFile };
}

function runPreflight(fixture, runId, extraEnv = {}) {
  const result = spawnSync("node", [preflightScript], {
    encoding: "utf8",
    env: {
      ...process.env,
      CODEX_MIND_MAINTAINER_RUN_ID: runId,
      CODEX_MIND_MAINTAINER_HOME: fixture.homeDir,
      CODEX_MIND_MAINTAINER_STATE_DIR: fixture.stateDir,
      CODEX_MIND_MAINTAINER_CACHE_DIR: fixture.cacheDir,
      CODEX_MIND_MAINTAINER_SHARED_AGENTS_URL: fixture.sharedAgentsFile,
      CODEX_MIND_MAINTAINER_SHARED_NOTES_REPO_URL: fixture.sharedNotesRepo,
      CODEX_MIND_MAINTAINER_SKILLS_REPO_URL: fixture.skillsRepo,
      CODEX_MIND_MAINTAINER_MODEL: "gpt-5.5",
      CODEX_MIND_MAINTAINER_REASONING: "high",
      ...extraEnv,
    },
  });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return JSON.parse(readFileSync(join(fixture.stateDir, "preflight", `${runId}-result.json`), "utf8"));
}

function initGit(directory) {
  git(directory, ["init", "-q"]);
  git(directory, ["config", "user.email", "test@example.invalid"]);
  git(directory, ["config", "user.name", "Preflight Test"]);
  git(directory, ["add", "."]);
  git(directory, ["commit", "-m", "Initial fixture"]);
}

function git(directory, args) {
  const result = spawnSync("git", ["-C", directory, ...args], { encoding: "utf8" });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

function writeFile(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
}

function workItemForPath(result, path) {
  const item = result.worklist.find((candidate) => candidate.path === path);
  assert.ok(item, `Expected worklist item for ${path}`);
  return item;
}

function appendDecision(stateDir, { runId, decision, recheck, item }) {
  const event = {
    schemaVersion: 1,
    timestamp: "2026-07-05T00:00:00.000Z",
    agentId: "test-agent",
    runId,
    model: "gpt-5.5",
    reasoningLabel: "high",
    policyVersion: "2026-07-05-preflight-v1",
    sourceIssue: "RYA-64",
    eventType: "reconciliation-decision",
    target: item.target,
    path: item.path,
    sharedRef: item.sharedRef,
    sharedHash: item.sharedHash,
    localHash: item.localHash,
    scope: item.scope,
    authority: item.authority,
    mergePolicy: item.mergePolicy,
    decision,
    rationale: "Manual test reconciliation decision.",
    recheck,
  };
  writeFileSync(join(stateDir, "reconciliation-ledger.jsonl"), `${JSON.stringify(event)}\n`, { flag: "a" });
}

function readLedger(stateDir) {
  return readFileSync(join(stateDir, "reconciliation-ledger.jsonl"), "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
}
