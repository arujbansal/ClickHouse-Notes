# Context for Claude: how this `documentation/` folder was built

Read this before editing anything in this folder. It captures the scope, conventions, sources, and known limitations so future edits don't drift.

## What this folder is

Contributor-facing architecture documentation for ClickHouse, written to complement (and go deeper than) the official page at <https://clickhouse.com/docs/development/architecture>. The intended reader is someone about to make a non-trivial PR — not a brand-new user, not a maintainer who already knows the code.

This is **not** official ClickHouse documentation. It lives under `documentation/` (not `docs/`) on purpose, so it doesn't collide with the upstream docs build (`docs/` has its own frontmatter / anchor rules — see the project `CLAUDE.md`). Don't move these files into `docs/` without first reformatting them to that toolchain's rules.

## How it was produced

1. The user asked for an in-depth, contributor-oriented expansion of the official architecture page.
2. Three setup questions were asked via `AskUserQuestion`:
   - **Structure:** one file per major subsystem, plus an overview file that ties everything together.
   - **Depth:** contributor-onboarding depth (key classes, responsibilities, data flow, `file:line` pointers; no per-line walkthroughs).
   - **Sources:** read the official page first, then build deeper on top of it.
3. Six `Explore` subagents ran in parallel, each covering one subsystem of the codebase. Their reports informed the corresponding `.md` files. The agents only reported; the writing in each file is mine, but the file:line pointers came from them.
4. Files were written in order: `00-overview.md` first (so cross-links from other files would resolve), then `01` through `08`.

## File map

| File | Subsystem | Primary code paths |
| --- | --- | --- |
| `00-overview.md` | Design principles, end-to-end query trace, call graph | (cross-cutting) |
| `01-core-data-model.md` | `IColumn`, `IDataType`, `Field`, `Block`, `Chunk` | `src/Columns/`, `src/DataTypes/`, `src/Core/`, `src/Processors/Chunk.h` |
| `02-query-frontend.md` | Parser, Analyzer, Planner, QueryPlan, Interpreters, executeQuery | `src/Parsers/`, `src/Analyzer/`, `src/Planner/`, `src/Processors/QueryPlan/`, `src/Interpreters/` |
| `03-processors-and-pipeline.md` | `IProcessor`, ports, `QueryPipeline`, `PipelineExecutor` | `src/Processors/`, `src/QueryPipeline/` |
| `04-storages-and-mergetree.md` | `IStorage`, engine families, MergeTree internals, replication | `src/Storages/`, `src/Storages/MergeTree/`, `src/Interpreters/DatabaseCatalog.h` |
| `05-functions.md` | Ordinary / aggregate / table functions, `ActionsDAG`, JIT | `src/Functions/`, `src/AggregateFunctions/`, `src/TableFunctions/`, `src/Interpreters/JIT/`, `src/Interpreters/ActionsDAG.h` |
| `06-io-and-formats.md` | Buffer hierarchy, compression, formats | `src/IO/`, `src/Compression/`, `src/Formats/`, `src/Processors/Formats/` |
| `07-distributed-and-coordination.md` | `StorageDistributed`, `RemoteQueryExecutor`, Keeper | `src/Storages/StorageDistributed*`, `src/Storages/Distributed/`, `src/QueryPipeline/RemoteQueryExecutor.h`, `src/Client/Connection.h`, `src/Coordination/` |
| `08-server-and-context.md` | Server startup, protocol handlers, `Context`, settings, access control, concurrency control | `programs/server/Server.cpp`, `src/Server/`, `src/Interpreters/Context.h`, `src/Core/Settings.h`, `src/Access/`, `src/Common/ConcurrencyControl.h` |

## Writing conventions (preserve these when editing)

- **Markdown link syntax for code references**, not backticks. The user uses the VSCode extension which makes these clickable: `[src/Foo/Bar.h](../../src/Foo/Bar.h)` or `[src/Foo/Bar.h:42](../../src/Foo/Bar.h#L42)`. The depth is `../../` because this folder lives at `ClickHouse-Notes/documentation/` and is symlinked into the ClickHouse repo as `<repo>/ClickHouse-Notes`, so a doc at `<repo>/ClickHouse-Notes/documentation/foo.md` needs to climb two directories to reach `<repo>/src/`. Backticks are still used for inline class/function/SQL names (e.g. `IColumn`, `MergeTree`), per the project `CLAUDE.md` rule about literal names from the SQL language / classes / functions.
- **No emojis.** None in the docs, none in `CLAUDE.md`.
- **No "see also" or "for more info" filler.** Cross-link by name with markdown links to the relevant other doc file or section.
- **Tables for taxonomies.** When listing engine families, processor types, combinator suffixes, etc., use a two-column markdown table. Prose for everything else.
- **`Why X, not Y` paragraphs.** Most subsystem files have at least one section that explains the rationale for a non-obvious design choice (immutable columns, prepare/work split, immutable parts, custom buffers). Keep these — they're the main reason this doc exists rather than just "read the headers."
- **Function names without parens** when referring to the function itself: `executeQuery`, not `executeQuery()`. Per the project `CLAUDE.md`.
- **"exception" not "crash"** when discussing logical errors. Per the project `CLAUDE.md`.
- **"ASan", not "ASAN".** Same source.
- **No co-author trailer in commit messages.** Per user memory `feedback_no_coauthor.md`.
- **Don't commit to `master`.** Per project `CLAUDE.md`. If asked to commit this folder, branch first.

## Known limitations / things deliberately omitted

These were left out for scope reasons; if asked to extend, **add new files** rather than ballooning existing ones.

- **Backups** (`src/Backups/`). Not covered. Touches `IStorage`, IO, Keeper.
- **Dictionaries** (`src/Dictionaries/`). Briefly referenced in `08`. The full system (sources, layouts, the `dictGet` family) deserves its own file.
- **Access control internals.** `08` covers the surface (`AccessControl`, `ContextAccess`); the row-policy injection mechanics and how roles are resolved into effective grants aren't detailed.
- **Async inserts** (`src/Interpreters/AsynchronousInsertQueue.h`). Mentioned in `07` only as a knob.
- **Window functions** specifics. `03` mentions them; the per-frame implementation isn't covered.
- **Query cache / query result cache / query condition cache.** Listed in `08` as caches, not explained.
- **Disks / storage policies** (`src/Disks/`). The on-disk part lives "on a disk"; the multi-disk / tiered-storage / object-storage abstraction isn't covered.
- **Server-side parts of `clickhouse-local`, `clickhouse-disks`, `clickhouse-keeper`** as separate binaries. Only the server is documented.
- **Newer schema-less / variant types** (`Object`, `Variant`, `Dynamic`, `JSON`). Mentioned in passing in `01`; the type system / subcolumn machinery for these is non-trivial and isn't covered.

## How file:line accuracy was handled

The Explore agents were asked for `file:line` pointers and produced many. **In the writing phase, line numbers were dropped from most references** because they rot fast in a repository this active. The docs link to files (and sometimes anchor `#L<line>`), but the prose mostly says "in `src/Foo/Bar.h`" rather than "at line 137." When line numbers do appear, they were correct as of the writing session but may drift; treat them as hints, not citations.

If the user reports a stale link, just drop the line anchor — don't go on a hunt to fix every reference.

## How to make changes

- **Small factual correction** (a class was renamed, a path moved): just edit the affected file. The cross-links between docs are by relative filename and section heading; if a heading changes, search for inbound links via grep.
- **Adding a subsystem** (backups, dictionaries, ...): create `09-<name>.md` (continue the numbering). Then update `00-overview.md`'s table at the top **and** the end-to-end query trace if the subsystem appears in it.
- **Expanding depth somewhere**: prefer adding a new section to the relevant file over creating a sibling. The current depth is calibrated as "what a contributor about to make a non-trivial PR needs to know" — going deeper is fine in places, but don't slide into a code-walkthrough.
- **Re-running fact-checks**: re-spawn `Explore` agents the same way as during the original build (one per subsystem, asking for current class names and entry points). Don't try to verify everything in one giant agent prompt — it gets shallow.

## What the user wanted that's not obvious from reading the docs

- **A single coherent document set, not 9 independent essays.** `00-overview.md` is load-bearing — every other file assumes the reader has the end-to-end query trace in their head. Keep `00` accurate as code moves.
- **Code-pointers, not code-excerpts.** Earlier iterations could have inlined snippets; the user explicitly chose "contributor-onboarding depth" over "deep dive with code excerpts." Resist the urge to paste code into these files.
- **Balanced abstraction.** The user warned against either extreme (too high-level to be useful, or "every line of every function"). When in doubt, name the class and explain why it exists; let the reader open the file for specifics.

## Quick checklist before committing edits to this folder

- [ ] All new code references use markdown links with `../../src/...` paths (the folder is consumed via a symlink at `<repo>/ClickHouse-Notes`, so two levels up reach `<repo>/src/`).
- [ ] No emojis, no co-author trailer in the commit message, branch is not `master`.
- [ ] Inline class/function/SQL names are in backticks; function names appear without parens.
- [ ] If a new file was added, `00-overview.md`'s top-of-file table includes it.
- [ ] If a doc structure changed, intra-folder links still resolve (no orphan anchors).
