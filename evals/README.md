# Evaluations

Ten questions that can only be answered by driving a real Roblox Studio session
through this server. They exist to answer "does an agent actually get anywhere
with these tools", which is a different question from "do the tools return 200".

## Why there is a fixture

Most MCP eval suites point at a fixed dataset — a repository, a wiki, an API
with stable records. This server has no dataset. It drives whatever place the
user happens to have open, so a question like "how many parts are in Workspace"
has a different answer every day and a different answer for every person.

So the suite brings its own place. `fixture.luau` builds a small scene under
`ReplicatedStorage.MCPEvalFixture` — tagged hazard parts with damage attributes,
three room models with differing numbers of lamps, and three scripts holding
constants and small functions. With it installed, every answer in
`roblox-studio.xml` is true in any place, on any machine.

It is idempotent: running it again destroys what it built and rebuilds it, so an
interrupted run or a fixture someone poked at by hand costs nothing. Nothing in
it runs — the scripts are disabled, and exist to be read and searched.

## Running

Open Studio with the plugin connected, then install the fixture:

```
execute_luau  with the contents of evals/fixture.luau
```

Ask an agent the questions in `roblox-studio.xml` and compare its answers to the
ones recorded there. When finished:

```
delete  ReplicatedStorage.MCPEvalFixture
```

## What the questions are for

Each one needs several tools and at least one step the answer cannot be guessed
from. They are spread across the surface deliberately:

| question | what it forces |
|---|---|
| 1, 2, 7 | `find` filtering by tag *and* property together, then `inspect` for attributes — the combination that replaces six tools on competing servers |
| 3, 6, 10 | recursive search and counting across a nested hierarchy, where a listing of direct children gives the wrong answer |
| 4, 5, 9 | `script_grep` to locate code, `script_read` to read it, then arithmetic on constants that are deliberately not round — a model that guesses plausibly gets them wrong |
| 8 | tracing a dependency between two scripts rather than reading one in isolation |

Answers were produced by solving each question with these tools against a live
session, then recorded. They were not read off the fixture source. That
distinction matters: a suite whose answers come from the generator tests the
generator, and would pass against a server that returned nothing at all.
