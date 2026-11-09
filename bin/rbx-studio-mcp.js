#!/usr/bin/env node
/**
 * Launches the native server for this platform.
 *
 * npm installs exactly one of the optional `@el4cteo/rbx-studio-mcp-<os>-<cpu>`
 * packages, which holds the prebuilt binary. This only finds it and hands over
 * stdio, signals and the exit code; the server itself is the binary.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const exe = process.platform === "win32" ? "rbx-studio-mcp.exe" : "rbx-studio-mcp";
const target = `${process.platform}-${process.arch}`;

function locate() {
  if (process.env.RBX_STUDIO_MCP_BINARY) return process.env.RBX_STUDIO_MCP_BINARY;
  try {
    const require = createRequire(import.meta.url);
    const manifest = require.resolve(`@el4cteo/rbx-studio-mcp-${target}/package.json`);
    const found = join(dirname(manifest), "bin", exe);
    if (existsSync(found)) return found;
  } catch {
    /* not installed for this platform */
  }
  // A source checkout: the newest local build.
  const root = join(dirname(fileURLToPath(import.meta.url)), "..");
  return ["release", "debug"].map((p) => join(root, "server", "target", p, exe)).find(existsSync);
}

const binary = locate();
if (!binary) {
  process.stderr.write(
    `rbx-studio-mcp: no prebuilt server for ${target}. Supported: win32-x64, win32-arm64, darwin-arm64, darwin-x64.\n` +
      "Reinstall without --no-optional, or build from source: cargo build --release --manifest-path server/Cargo.toml\n",
  );
  process.exit(1);
}

const child = spawn(binary, process.argv.slice(2), { stdio: "inherit", windowsHide: true });
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => child.kill(signal));
}
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 0);
});
child.on("error", (cause) => {
  process.stderr.write(`rbx-studio-mcp: could not start ${binary}: ${cause.message}\n`);
  process.exit(1);
});
