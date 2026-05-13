# ClickHouse-Notes

Personal notes on the ClickHouse codebase.

## `documentation/`

Contributor-oriented architecture documentation for ClickHouse, written to complement (and go deeper than) the official page at <https://clickhouse.com/docs/development/architecture>. The intended reader is someone about to make a non-trivial PR — not a brand-new user, not a maintainer who already knows the code.

This is **not** official ClickHouse documentation. The files cover each major subsystem (core data model, query frontend, processors and pipeline, storages and MergeTree, functions, I/O and formats, distributed execution, server lifecycle, the `IStorage` hierarchy), plus an overview that traces a query end-to-end and ties everything together. Start at [documentation/00-overview.md](documentation/00-overview.md).

Code references inside these docs are markdown links with `../../src/...` paths, which assumes the folder is consumed via a symlink at `<clickhouse-repo>/ClickHouse-Notes` — see below.

## `setup.sh`

Wires this notes checkout into a ClickHouse working copy so the code references resolve and the symlink stays out of git tracking.

```sh
./setup.sh /path/to/ClickHouse
```

It does two things:

1. Creates a symlink at `<clickhouse-repo>/ClickHouse-Notes` pointing back at this directory. With that in place, every `../../src/...` link inside `documentation/` resolves to the real file in the ClickHouse repo and is clickable in VSCode / any markdown viewer that follows relative links.
2. Appends `/ClickHouse-Notes` to `<clickhouse-repo>/.git/info/exclude` so the symlink is hidden from `git status` without touching the tracked `.gitignore`. `.git/info/exclude` is per-clone and not under version control, so this only affects your working copy.

Both steps are idempotent. The script refuses to clobber a pre-existing file or repoint a symlink that already points somewhere else; remove the conflicting entry by hand if you want to reset it.
