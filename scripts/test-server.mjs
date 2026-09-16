import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createServer } from "node:net";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const entrypoint = join(root, "dist", "index.js");
const packageVersion = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;

for (const args of [
  ["doctor", "--port"],
  ["doctor", "--port", "44755oops"],
  ["doctor", "--port", "12.5"],
]) {
  const result = spawnSync(process.execPath, [entrypoint, ...args], {
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(result.status, 1, `${args.join(" ")} must fail`);
  assert.match(result.stderr, /failed to start: (Invalid port|Missing value for --port)/);
}

const port = await new Promise((resolvePort, reject) => {
  const server = createServer();
  server.once("error", reject);
  server.listen(0, "127.0.0.1", () => {
    const address = server.address();
    if (address === null || typeof address === "string") {
      server.close();
      reject(new Error("Could not allocate a test port"));
      return;
    }
    server.close((cause) => cause ? reject(cause) : resolvePort(address.port));
  });
});

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [entrypoint, "--port", String(port)],
  cwd: root,
  stderr: "pipe",
});
const client = new Client({ name: "server-metadata-test", version: "1.0.0" });

try {
  await client.connect(transport);
  assert.equal(
    client.getServerVersion()?.version,
    packageVersion,
    "MCP server version must match package.json",
  );
} finally {
  await client.close();
}

process.stdout.write("server metadata: ok\n");
