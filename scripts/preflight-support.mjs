import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { spawnSync } from "node:child_process";

export function updateGitCache(directory, repoUrl) {
  mkdirSync(dirname(directory), { recursive: true });
  if (!existsSync(directory)) {
    run("git", ["clone", "--quiet", "--depth=1", repoUrl, directory]);
  } else {
    if (!existsSync(join(directory, ".git"))) {
      throw new Error(`Cache path exists but is not a git repository: ${directory}`);
    }
    run("git", ["-C", directory, "remote", "set-url", "origin", repoUrl]);
    run("git", ["-C", directory, "fetch", "--quiet", "--prune", "origin"]);
    run("git", ["-C", directory, "checkout", "--quiet", "--detach", remoteDefaultRef(directory)]);
  }
  return run("git", ["-C", directory, "rev-parse", "--short=12", "HEAD"]).stdout.trim();
}

export function readSharedAgents(sharedNotesDirectory, url, defaultUrl) {
  const localPath = join(sharedNotesDirectory, "AGENTS.shared.md");
  if ((url === defaultUrl || !url) && existsSync(localPath)) {
    return readFileSync(localPath, "utf8");
  }
  if (url.startsWith("file://")) {
    return readFileSync(new URL(url), "utf8");
  }
  if (existsSync(url)) {
    return readFileSync(url, "utf8");
  }
  if (url.startsWith("http://") || url.startsWith("https://")) {
    return run("curl", ["--fail", "--silent", "--show-error", "--location", url]).stdout;
  }
  throw new Error(`Shared AGENTS URL is not available from deterministic cache or local file: ${url}`);
}

export function gitFiles(directory) {
  const output = run("git", ["-C", directory, "ls-files", "-z"]).stdout;
  return output.split("\0").filter(Boolean).sort();
}

export function skillWorkItems(skillsDirectory, skillsRef, home, workItem) {
  const codexHome = process.env.CODEX_HOME ?? join(home, ".codex");
  const installedSkillsDir = join(codexHome, "skills");
  return readdirSync(skillsDirectory, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .filter((entry) => existsSync(join(skillsDirectory, entry.name, "SKILL.md")))
    .flatMap((entry) => {
      const sharedPath = join(skillsDirectory, entry.name);
      const localPath = join(installedSkillsDir, entry.name);
      const sharedHash = hashDirectory(sharedPath);
      const localHash = existsSync(localPath) ? hashDirectory(localPath) : null;
      if (sharedHash === localHash) {
        return [];
      }
      return [workItem({
        target: "skill-install",
        path: entry.name,
        reason: localHash === null
          ? "Shared skill is not installed locally."
          : "Installed skill differs from shared skills source.",
        sharedRef: skillsRef,
        sharedHash,
        localHash,
        mergePolicy: "shared-owned",
        authority: "shared",
        scope: "local",
      })];
    });
}

export function readLedger(path) {
  if (!existsSync(path)) {
    return [];
  }
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        throw new Error(`Invalid JSONL ledger entry at ${path}:${index + 1}: ${error.message}`);
      }
    });
}

export function renderWorklist(result) {
  const lines = [
    "# Mind Maintainer Preflight Worklist",
    "",
    `Run ID: ${result.runId}`,
    `Policy version: ${result.policyVersion}`,
    `Shared durable notes ref: ${result.sharedNotesRef}`,
    `Shared skills ref: ${result.skillsRef}`,
    `Ledger: ${result.ledgerPath}`,
    "",
    result.summary,
    "",
  ];
  result.worklist.forEach((item, index) => {
    lines.push(`## ${index + 1}. ${item.target}${item.path ? `: ${item.path}` : ""}`);
    lines.push("");
    lines.push(`- Reason: ${item.reason}`);
    lines.push(`- Scope: ${item.scope}`);
    lines.push(`- Authority: ${item.authority}`);
    lines.push(`- Merge policy: ${item.mergePolicy}`);
    lines.push(`- Shared ref: ${item.sharedRef ?? "n/a"}`);
    lines.push(`- Shared hash: ${item.sharedHash ?? "n/a"}`);
    lines.push(`- Local hash: ${item.localHash ?? "n/a"}`);
    lines.push("");
  });
  lines.push("Use this worklist as the default scope for full maintenance. Append final reconciliation decisions to the JSONL ledger.");
  lines.push("");
  return `${lines.join("\n")}\n`;
}

export function extractManagedBlock(content) {
  const begin = "<!-- BEGIN SHARED_AGENT_GUIDANCE -->";
  const end = "<!-- END SHARED_AGENT_GUIDANCE -->";
  const beginIndex = content.indexOf(begin);
  const endIndex = content.indexOf(end);
  if (beginIndex === -1 || endIndex === -1 || endIndex < beginIndex) {
    return content;
  }
  return content.slice(beginIndex, endIndex + end.length);
}

export function hashText(text) {
  return `sha256:${createHash("sha256").update(text).digest("hex")}`;
}

export function hashFile(path) {
  return `sha256:${createHash("sha256").update(readFileSync(path)).digest("hex")}`;
}

export function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

export function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

export function truthy(value) {
  return value === "1" || value === "true" || value === "yes";
}

function remoteDefaultRef(directory) {
  const symbolic = spawnSync("git", ["-C", directory, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], {
    encoding: "utf8",
  });
  if (symbolic.status === 0 && symbolic.stdout.trim()) {
    return symbolic.stdout.trim();
  }
  for (const candidate of ["origin/main", "origin/master"]) {
    const check = spawnSync("git", ["-C", directory, "rev-parse", "--verify", candidate], {
      encoding: "utf8",
    });
    if (check.status === 0) {
      return candidate;
    }
  }
  throw new Error(`Unable to determine default branch for cache: ${directory}`);
}

function hashDirectory(directory) {
  const files = recursiveFiles(directory);
  const hash = createHash("sha256");
  for (const file of files) {
    const rel = relative(directory, file).replaceAll("\\", "/");
    hash.update(rel);
    hash.update("\0");
    hash.update(readFileSync(file));
    hash.update("\0");
  }
  return `sha256:${hash.digest("hex")}`;
}

function recursiveFiles(directory) {
  if (!existsSync(directory)) {
    return [];
  }
  return readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      if (entry.name === ".git" || entry.name === ".install-backups") {
        return [];
      }
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        return recursiveFiles(path);
      }
      if (entry.isFile()) {
        return [path];
      }
      return [];
    })
    .sort();
}

function run(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.status !== 0) {
    const stderr = result.stderr.trim();
    const stdout = result.stdout.trim();
    throw new Error(`Command failed: ${command} ${args.join(" ")}${stderr ? `\n${stderr}` : ""}${stdout ? `\n${stdout}` : ""}`);
  }
  return result;
}
