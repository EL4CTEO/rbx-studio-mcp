# API candidates

Roblox APIs this server does not use yet, and whether they are worth a tool.
Research only — nothing here is implemented.

Every claim about a class or method was checked against the live API dump the
`api` tool already fetches
([Roblox-Client-Tracker](https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json)),
not from memory. Security level is quoted from the dump because it decides
whether a plugin can call the thing at all.

## The bar

`create`, `modify`, `delete`, `move` and `inspect` already reach **any instance
and any property**. A "Lighting tool" or a "SoundService tool" would be a
second, narrower way to set properties that are already settable, and would
spend schema tokens saying so — this server's ~16k budget against 43–51 tools
elsewhere is a feature worth defending.

So a new tool has to clear one of two bars:

1. **It is a method, not a property.** Terrain voxels, mesh generation and
   solid modelling are calls with their own argument shapes; nothing generic
   reaches them.
2. **`execute_luau` does it badly.** The escape hatch already works for all of
   these. It is worth replacing when the Luau is long enough to get wrong, when
   the result needs structuring the agent cannot do inline, or when the
   operation must land as one undo step — which is the thing `execute_luau`
   cannot give you.

Anything that fails both bars belongs in the README's "not built here" list.

## Ranked candidates

### 1. Terrain — `Workspace.Terrain`

66 members, security `None`, no beta flag. The README lists terrain as
explicitly not built, and it is the largest genuine gap.

The useful surface is small: `FillBlock`, `FillBall`, `FillCylinder`,
`FillWedge`, `FillRegion` to write; `ReplaceMaterial` to repaint; `ReadVoxels` /
`WriteVoxels` for bulk work; `Clear`, `CopyRegion` / `PasteRegion`;
`WorldToCell` and friends for coordinates.

Clears both bars. A terrain edit is a method call with a CFrame, a size and a
material, it is tedious and error-prone to write as inline Luau, and a batch of
fills wants to be one `ChangeHistoryService` recording the way every other write
tool in this server already is.

Cost: one `terrain` tool with an `op` discriminator, following the shape
`geometry` and `playtest` already use. Note `ReadVoxels` is tagged
`CustomLuaState` and returns two large multidimensional arrays — a raw voxel
read must be summarised before it crosses the wire, never returned whole.

### 2. GenerationService — 4D / mesh generation

`GenerateModelAsync`, `GenerateMeshAsync`, `LoadGeneratedMeshAsync`,
`SegmentMeshAsync`, `ExportMeshToGlbAsync`, `LoadModelFromGlbAsync`. All
security `None`, all `Yields`.

Watch the deprecation: Roblox moved to `GenerateModelAsync` ("4D Generation",
beta to all creators in February 2026) and announced the older mesh-generation
API for removal. Anything built here should target `GenerateModelAsync` and
treat `GenerateMeshAsync` as legacy.

Clears bar 1. Real caveats before building it: generation is slow (well past the
15s default deadline, so it needs its own `timeoutMs` like `world.ts` already
does at 120s), it is metered per creator, and it can fail for content reasons
that need to reach the agent as a hint rather than a stack trace.

### 3. GeometryService — the parts not used yet

The `geometry` tool covers `UnionAsync`, `SubtractAsync`, `IntersectAsync` and
`FragmentAsync`. Untouched and security `None`:

- **`SweepPartAsync`** — the volume a part sweeps through a motion. Genuinely
  hard to do any other way, and the natural answer to "does this door clip the
  wall when it opens".
- **`CreateSolidPrimitive`** — primitives as `PartOperation`s.
- **`GenerateFragmentSites`** — fracture points without committing the fracture.

Cheapest of the three to add: new ops on the tool that already exists, so the
schema cost is a few lines rather than a tool.

### 4. AssetService — publishing

`CreateAssetAsync` / `CreateAssetVersionAsync` (security `None`) let a plugin
upload an asset. `CreateMeshPartAsync` and `CreateEditableMeshAsync` build
geometry in memory.

Clears bar 1, but this is the one candidate that acts **outside** the user's
machine — it publishes to their Roblox account. That deserves a deliberate
decision rather than a default, and probably an explicit opt-in, which is a
product question before it is an implementation one.

### 5. TextService — `GetTextBoundsAsync`

Security `None`, `Yields`. Measures rendered text. Small and dull, and the only
honest answer to "will this label fit"; every alternative is a guess. Worth it
only if UI work turns out to be common.

## Looks like a gap, is not

- **`Selection`** — already read by `studio_status` (`handlers/Session.luau:114`)
  and written by `viewport op="select"` (`handlers/Viewport.luau:118-122`).
- **`ScriptEditorService` documents** — `Editor.luau` already reports open tabs,
  cursor position and selected text, which is the "what is the user looking at"
  question. Nothing left to add.
- **`EditableImage`** — already used, by the screenshot path (`Png.luau`,
  `handlers/Capture.luau`).
- **Lighting, MaterialService, SoundService, ServerStorage** — reachable through
  `modify` and `inspect` today; they appear in `Scope.luau` as path roots. A
  dedicated tool would be a second way to set properties.
- **`CollectionService`** — tags are already read and written by `inspect`,
  `find` and `create`/`modify`.

## SSE, stdio and poll are not one question

The comparison gets made wrongly, so, plainly: there are two legs and they have
different answers.

**MCP client ↔ server is stdio** (`src/index.ts:115`) and should stay stdio.
One client drives one process over a pipe it owns. An HTTP or SSE MCP transport
here would add a port, a lifetime and an authentication story in exchange for
nothing.

**Server ↔ Studio plugin is where the claim lives.** The plugin cannot be
listened to — it is inside Studio and has to reach *out* — so the server's only
options are to push down a connection the plugin opens (SSE, via
`HttpService:CreateWebStreamClient`) or to answer a request the plugin keeps
making (long-poll, which is what every other Roblox Studio MCP does).

Measured, both transports, one machine, 50 sequential round trips
(`node scripts/latency.mjs --count 50 --compare`): **13.6 ms mean / 12.8 ms
median over SSE against 25.8 ms / 29.9 ms polling.** Sequential rather than
concurrent because an agent waits for each answer before choosing what to ask
next.

The honest caveats, both already handled in code:

- Studio allows **4 concurrent web streams per process, shared with every other
  installed plugin** (`Transport.luau:5-15`). A session can fail to get one
  through no fault of its own, which is why the long-poll fallback exists and
  why `studio transport` can force it.
- Studio closes a stream at **30 minutes**, so reconnects are routine rather
  than exceptional (`Transport.luau:81-88`), and pending calls are deliberately
  kept alive across the gap (`rpc.ts:81-90`).
- A poll session that recovers is not left there: a healthy poll loop stands
  aside every `RESTREAM_INTERVAL` (60s) so streaming can be retried. Without
  that, one unlucky attempt downgraded a session permanently and nothing
  reported it.
