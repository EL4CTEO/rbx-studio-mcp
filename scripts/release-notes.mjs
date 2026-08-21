/**
 * Pulls one version's section out of CHANGELOG.md for the release body.
 *
 * Exists so a release cannot go out without notes. GitHub's own
 * `generate_release_notes` lists commit subjects, which are written for whoever
 * reads the diff and say nothing useful to someone deciding whether to upgrade.
 * Failing the workflow on a missing section is the point: the alternative is a
 * tag that quietly publishes with an empty body, which is what happened for
 * 0.1.1 through 0.1.3.
 *
 * Usage: node scripts/release-notes.mjs <version> <outFile>
 */
import { readFileSync, writeFileSync } from "node:fs";

const [, , rawVersion, outFile] = process.argv;
if (!rawVersion || !outFile) {
  throw new Error("usage: release-notes.mjs <version> <outFile>");
}

// Tags carry a leading v; the changelog headings do not.
const version = rawVersion.replace(/^v/, "");
const changelog = readFileSync("CHANGELOG.md", "utf8");

// Everything from this version's heading up to the next one, so adding a
// release never means touching the extractor.
const heading = new RegExp(`^## ${version.replace(/\./g, "\\.")}\\s*$`, "m");
const start = changelog.search(heading);
if (start === -1) {
  throw new Error(
    `CHANGELOG.md has no "## ${version}" section. Add one describing what changed ` +
      `before tagging, or the release would publish with an empty body.`,
  );
}

const body = changelog.slice(start).split("\n").slice(1).join("\n");
const next = body.search(/^## /m);
const section = (next === -1 ? body : body.slice(0, next)).trim();

if (section.length === 0) {
  throw new Error(`The "## ${version}" section in CHANGELOG.md is empty.`);
}

writeFileSync(outFile, `${section}\n`);
