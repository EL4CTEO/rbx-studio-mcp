/**
 * Builds plugin/src into an installable StudioMCP.rbxmx.
 *
 * Rojo would do this too, but requiring contributors (and users building from
 * source) to install a Luau toolchain just to get a plugin file is friction the
 * project does not need. The .rbxmx format is plain XML, so we emit it directly
 * and keep `plugin/default.project.json` around for people who do use Rojo.
 *
 * Usage: node scripts/build-plugin.mjs [outputPath]
 */
import { readdirSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceDir = join(root, "plugin", "src");
const outputPath = resolve(process.argv[2] ?? join(root, "build", "StudioMCP.rbxmx"));

let nextReferent = 0;

/** XML text escaping for property values (source goes in CDATA instead). */
const escapeXml = (value) =>
  value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

/**
 * Wraps Luau source in CDATA. A literal "]]>" would close the section early, so
 * it is split across two adjacent sections — the parser rejoins them.
 */
const cdata = (source) => `<![CDATA[${source.replaceAll("]]>", "]]]]><![CDATA[>")}]]>`;

function renderItem(node, depth) {
  const pad = "  ".repeat(depth);
  const referent = `RBX${nextReferent++}`;
  const properties = [`${pad}    <string name="Name">${escapeXml(node.name)}</string>`];

  if (node.source !== undefined) {
    properties.push(`${pad}    <ProtectedString name="Source">${cdata(node.source)}</ProtectedString>`);
  }
  if (node.className === "Script") {
    // Plugin scripts must not be disabled, and RunContext 0 (Legacy) is what
    // Studio expects for code running in the plugin's own context.
    properties.push(`${pad}    <bool name="Disabled">false</bool>`);
    properties.push(`${pad}    <token name="RunContext">0</token>`);
  }

  const children = node.children.map((child) => renderItem(child, depth + 1)).join("\n");

  return [
    `${pad}<Item class="${node.className}" referent="${referent}">`,
    `${pad}  <Properties>`,
    ...properties,
    `${pad}  </Properties>`,
    ...(children ? [children] : []),
    `${pad}</Item>`,
  ].join("\n");
}

/**
 * Mirrors Rojo's naming rules: `init.server.luau` turns its folder into a
 * Script, `init.luau` into a ModuleScript, and every other .luau file becomes a
 * ModuleScript child. That keeps this builder and Rojo producing the same tree.
 */
function buildTree(dir, name) {
  const node = { name, className: "Folder", children: [] };

  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const path = join(dir, entry.name);

    if (entry.isDirectory()) {
      node.children.push(buildTree(path, entry.name));
      continue;
    }
    if (!entry.name.endsWith(".luau")) continue;

    const source = readFileSync(path, "utf8");
    if (entry.name === "init.server.luau") {
      node.className = "Script";
      node.source = source;
    } else if (entry.name === "init.luau") {
      node.className = "ModuleScript";
      node.source = source;
    } else {
      node.children.push({
        name: entry.name.replace(/\.luau$/, ""),
        className: "ModuleScript",
        source,
        children: [],
      });
    }
  }

  return node;
}

const tree = buildTree(sourceDir, "StudioMCP");
const document = [
  '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime"',
  '  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
  '  xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
  renderItem(tree, 1),
  "</roblox>",
  "",
].join("\n");

mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, document, "utf8");
