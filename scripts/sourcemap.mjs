/**
 * Emits a luau-lsp sourcemap for plugin/src.
 *
 * luau-lsp needs one to resolve `script.Parent.Foo` requires. Maintaining it by
 * hand meant every new module was invisible to the type checker until someone
 * noticed, so it is generated from the same naming rules build-plugin.mjs uses.
 *
 * Usage: node scripts/sourcemap.mjs [outputPath]
 */
import { readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceDir = join(root, "plugin", "src");
const outputPath = resolve(process.argv[2] ?? join(root, "sourcemap.json"));

/**
 * luau-lsp resolves a sourcemap's filePaths against the working directory
 * rather than against the sourcemap file, so they are written relative to the
 * repo root, and always with forward slashes.
 */
const relativePath = (path) => relative(root, path).split("\\").join("/");

function buildTree(dir, name) {
  const node = { name, className: "Folder", filePaths: [], children: [] };

  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
    a.name.localeCompare(b.name),
  )) {
    const path = join(dir, entry.name);

    if (entry.isDirectory()) {
      node.children.push(buildTree(path, entry.name));
      continue;
    }
    if (!entry.name.endsWith(".luau")) continue;

    if (entry.name === "init.server.luau") {
      node.className = "Script";
      node.filePaths.push(relativePath(path));
    } else if (entry.name === "init.luau") {
      node.className = "ModuleScript";
      node.filePaths.push(relativePath(path));
    } else {
      node.children.push({
        name: entry.name.replace(/\.luau$/, ""),
        className: "ModuleScript",
        filePaths: [relativePath(path)],
        children: [],
      });
    }
  }

  return node;
}

writeFileSync(outputPath, JSON.stringify(buildTree(sourceDir, "StudioMCP"), null, 2) + "\n", "utf8");
