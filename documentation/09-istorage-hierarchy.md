# The `IStorage` class hierarchy

[04-storages-and-mergetree.md](04-storages-and-mergetree.md) introduces `IStorage` as the interface every table engine implements and lists the engine families. This file goes one layer deeper: it walks the C++ inheritance tree below [src/Storages/IStorage.h](../../src/Storages/IStorage.h), explains *why* each intermediate base class exists, and gives a careful treatment of `StorageWithCommonVirtualColumns`, which is easy to misread on first contact.

The intent here is so that when you open a new `Storage*.h` file and see a base class you don't recognize, you know which contract the engine is buying into — and which methods are yours to override versus which are already handled for you.

## The top of the tree

[`IStorage`](../../src/Storages/IStorage.h) is the root. It defines:

- The lifecycle methods (`read`, `write`, `alter`, `mutate`, `optimize`, `drop`, `truncate`, `rename`).
- Metadata access (`getInMemoryMetadataPtr`, `getStorageSnapshot`).
- Capability flags (`supportsX`).
- Identity (`StorageID`, `getName`).

Concrete engines fall into a few categories based on where they sit relative to `IStorage`:

| Pattern | Base class | When you'd use it |
| --- | --- | --- |
| Plain engine | `IStorage` directly | Engines that don't share virtual-column conventions with the rest of the system, or that need full control over `read`. |
| Engine with cross-cutting ephemerals | `StorageWithCommonVirtualColumns` | The common case for any engine that wants `_table` / `_database` (and similar) handled uniformly. |
| MergeTree-family engine | `MergeTreeData` (which itself derives from `IStorage`) | Anything built on the parts-and-merges model. |
| Cluster fan-out wrapper | `IStorageCluster` | `s3Cluster`, `hdfsCluster`, `urlCluster`, etc. — table functions that distribute work across a cluster. |
| URL-shaped integration | `IStorageURLBase` | `StorageURL`, `StorageXDBC`. |
| Wrapping another storage | `StorageProxy` | View-like engines that delegate every method to a nested `StoragePtr`. |

The rest of this file is one section per base class.

## `StorageWithCommonVirtualColumns`

[src/Storages/StorageWithCommonVirtualColumns.h](../../src/Storages/StorageWithCommonVirtualColumns.h) / [.cpp](../../src/Storages/StorageWithCommonVirtualColumns.cpp). This is the class that needs the most explanation, because its purpose only becomes clear once you know how ClickHouse handles virtual columns.

### What "virtual columns" are

Virtual columns are columns that aren't part of the table's declared schema but can still appear in a `SELECT` list. They fall into two kinds (the `VirtualsKind` enum in [src/Storages/ColumnsDescription.h](../../src/Storages/ColumnsDescription.h)):

- **Ephemeral** — computed at query time, never stored. Examples: `_table`, `_database`, `_part`, `_part_offset`, `_path`, `_file`, `_shard_num`. These are derived from the query's runtime context (which table you're reading from, which part a row came from, which file a row was parsed from, ...).
- **Persistent** — physically stored alongside ordinary columns, but absent from the user-visible schema. Examples in MergeTree: `_row_exists` (lightweight delete marker), `_block_number`, `_block_offset`. The user can `SELECT` them but never `INSERT` into them.

There's a second axis (`VirtualsMaterializationPlace` in the same file): **where** an ephemeral virtual column gets filled in.

- **Reader** — the source processor itself emits the column as part of its output chunks. The MergeTree source knows the part name, so it can attach `_part` directly. This is the only option for virtuals whose value varies per row or per source.
- **Plan** — the column is constant for the whole storage read, so the query plan can paint it on at the end with a single `ExpressionStep` that adds a constant column. `_table` and `_database` for a non-`Merge` storage are the canonical example: every row read from `db.t` has the same `_table = 't'`, so there's no point making the source emit it.

`StorageWithCommonVirtualColumns` exists for the **Plan-place ephemeral** case.

### The mechanic

A storage that derives from `StorageWithCommonVirtualColumns` does **not** override the public `read(QueryPlan&, ...)`. It overrides `readImpl(...)` instead. The base class's `read` does three things:

1. **Strip out the Plan-place virtuals** from the requested column list, so the underlying storage never sees them in its read request. (`VirtualColumnUtils::filterVirtualColumns(..., VirtualsKind::Ephemeral, VirtualsMaterializationPlace::Plan)`.)
2. **Call `readImpl`** with the filtered list. The subclass produces a `QueryPlan` source step that reads only the columns it actually has.
3. **Append `ExpressionStep`s** that materialize the requested Plan-place virtuals as constant columns: `_database` becomes the storage's database name, `_table` becomes its table name (or the temporary-table name if applicable). Finally, a converting step reorders columns back to the sequence the caller asked for.

Step 3 is the value-add. Every engine that wanted `_table` / `_database` would otherwise have to duplicate this constant-column-appending logic. Centralizing it means a new engine just registers the virtuals (`desc.addEphemeral("_table", ..., VirtualsMaterializationPlace::Plan)` — see e.g. [StorageDummy.cpp:42](../../src/Storages/StorageDummy.cpp#L42)) and inherits the materialization for free.

There's one bypass: when `processed_stage > QueryProcessingStage::FetchColumns`, the base class skips the filtering and just delegates to `readImpl`. This happens when the storage handles the query past the read stage itself (`StorageDistributed`, `StorageMerge`, `StorageView`) — in those cases the upper layers of the query are running inside the storage, and adding plan-level constant columns at the end would be wrong.

### Why it's not used everywhere

It's tempting to ask: why not make every storage derive from this? Two reasons:

- **Reader-place virtuals are different.** MergeTree's `_part`, `_part_offset`, etc. vary per row — there's no constant to paint on at the plan level. MergeTree handles its own virtuals inside `MergeTreeSelectProcessor`. (MergeTree happens to *also* expose `_table` and `_database` as Reader-place virtuals — see [MergeTreeData.cpp:790-791](../../src/Storages/MergeTree/MergeTreeData.cpp#L790-L791) — so it doesn't go through this base class.)
- **Some storages need full control of `read`.** `StorageDistributed`, `StorageMerge`, `StorageBuffer`, `StorageFile`, `StorageNull`, `StorageValues` all derive directly from `IStorage` either because they don't want `_table`/`_database` injected this way, or because their `read` already does something incompatible with the wrap-and-append model.

### Subclasses

A non-exhaustive list to give a sense of who uses it: `StorageMemory`, `StorageLog`, `StorageStripeLog`, `StorageDictionary`, `StorageView`, `StorageMaterializedView`, `StorageMySQL`, `StoragePostgreSQL`, `StorageMongoDB`, `StorageSQLite`, `StorageRedis`, `StorageKeeperMap`, `StorageArrowFlight`, `StorageGenerateRandom`, `StorageFuzzJSON`, `StorageFuzzQuery`, `StorageInput`, `StorageExecutable`, `StorageDummy`, `StorageTimeSeries`, `StorageMergeTreeIndex`, `StorageMergeTreeTextIndex`, `StoragePrometheusQuery`, `StorageSetOrJoinBase`.

The pattern they all share: their data comes from a single conceptual source (one external system, one in-memory blob, one dictionary, one log file), so `_table`/`_database` are constants for the whole read.

## `MergeTreeData`

[src/Storages/MergeTree/MergeTreeData.h](../../src/Storages/MergeTree/MergeTreeData.h) is the shared base for every engine in the MergeTree family. It is a direct child of `IStorage` (not of `StorageWithCommonVirtualColumns`).

`MergeTreeData` is doing *much* more than `IStorage` requires:

- Manages the **active parts set** (`DataParts`), part lifecycle (committed / outdated / temporary), and the data-parts mutex.
- Owns part loading, part name parsing, the partition expression, the sorting/primary key, secondary indices, projections, TTL expressions.
- Provides `MergeTreeDataSelectExecutor` for read planning and `MergeTreeDataWriter` for the write path.
- Provides `getVirtuals()` returning the MergeTree-specific virtual column set (`_part`, `_part_index`, `_part_starting_offset`, `_part_uuid`, `_partition_id`, `_sample_factor`, `_part_offset`, `_part_granule_offset`, `_part_data_version`, `_disk_name`, `_distance`, `_table`, `_database`, optionally `_partition_value`) plus the persistent ones (`_row_exists`, `_block_number`, `_block_offset`). See [MergeTreeData.cpp:779-801](../../src/Storages/MergeTree/MergeTreeData.cpp#L779-L801).

Two concrete subclasses:

| Class | Role |
| --- | --- |
| [`StorageMergeTree`](../../src/Storages/StorageMergeTree.h) | The single-replica engine. Owns the background-task scheduler and a local mutations queue. |
| [`StorageReplicatedMergeTree`](../../src/Storages/StorageReplicatedMergeTree.h) | Adds the Keeper-coordinated replication log on top. See [04-storages-and-mergetree.md](04-storages-and-mergetree.md#replicated-mergetree). |

All the user-facing variants (`ReplacingMergeTree`, `SummingMergeTree`, `AggregatingMergeTree`, `CollapsingMergeTree`, ...) are not separate C++ classes — they're a `MergingParams` enum on `MergeTreeData` that changes how the merge step combines rows. The class hierarchy is just `StorageMergeTree` / `StorageReplicatedMergeTree`.

There are also two specialty subclasses of `IStorage` that wrap MergeTree internals to expose them as readable tables:

- [`StorageFromMergeTreeDataPart`](../../src/Storages/MergeTree/StorageFromMergeTreeDataPart.h) — read a single part as if it were a table. Used during merges/mutations and by `system.parts`-style introspection.
- [`StorageFromMergeTreeProjection`](../../src/Storages/MergeTree/StorageFromMergeTreeProjection.h) — read a projection as a table. Used by the planner when it transparently rewrites a query to read from a projection.

## `IStorageCluster`

[src/Storages/IStorageCluster.h](../../src/Storages/IStorageCluster.h). Base for the `*Cluster` engines that exist purely to fan a single-server table function out across a `Cluster`: `s3Cluster`, `hdfsCluster`, `urlCluster`, `fileCluster`, `azureBlobStorageCluster`, etc.

The contract:

- `read` is implemented in the base class and constructs a `ReadFromCluster` plan step.
- The subclass must implement `getTaskIteratorExtension`, which decides how work (e.g. the list of S3 keys) gets partitioned among the cluster's replicas. The iterator runs on the initiator and hands tasks to remote workers on demand.
- `isRemote()` is hard-coded to `true`.

This isn't conceptually different from `StorageDistributed` (also a fan-out engine), but the workload is different: cluster table functions don't have a per-shard table to query, they have a stream of *file-like tasks* to hand out to whichever replica has capacity. `IStorageCluster` provides the iterator-and-stream machinery that pattern needs.

Concrete subclasses include `StorageS3Cluster`, `StorageURLCluster`, `StorageFileCluster`, `StorageHDFSCluster`, `StorageAzureBlobCluster`, etc.

## `IStorageURLBase`

[src/Storages/StorageURL.h](../../src/Storages/StorageURL.h). Base for engines that read/write rows by talking to an HTTP-shaped endpoint. The two concrete derivations:

- [`StorageURL`](../../src/Storages/StorageURL.h) — generic `url(...)` table function and `URL` table engine. `StorageURLWithFailover` is a private variant used only inside the URL table function for multi-URL retry behavior.
- [`StorageXDBC`](../../src/Storages/StorageXDBC.h) — the ODBC/JDBC bridge engines, which use the same HTTP plumbing to talk to the bridge process.

The shared logic in `IStorageURLBase` covers HTTP method selection, format inference, retry behavior, partitioned writes, the `StorageURLSource` / `StorageURLSink` processors, and the URL-specific virtual columns (`_path`, `_file`, `_size`, `_time`, `_etag`).

## `StorageProxy`

[src/Storages/StorageProxy.h](../../src/Storages/StorageProxy.h). Pattern: hold a `StoragePtr` to a nested storage and forward most methods to it.

Every capability query (`isRemote`, `supportsPrewhere`, `supportsReplication`, ...) returns `getNested()->...`. `read`, `write`, `alter`, etc. similarly delegate. The subclass exists to add a thin layer of behavior on top.

In practice this is used inside the database-engine plumbing — `DatabaseReplicated`, dictionary tables, lazy table loading — where a placeholder storage needs to defer to the real storage once it's ready.

## Direct `IStorage` derivations that don't fit a base class

Some engines derive straight from `IStorage` because none of the above patterns apply:

| Storage | Why direct |
| --- | --- |
| `StorageDistributed` | Fans out to a cluster of *tables* (not file-tasks). Has its own read/write/insert-routing machinery. |
| `StorageMerge` | Reads from a regex-matched set of underlying tables; per-row `_table`/`_database` are Reader-place virtuals because they vary by source. |
| `StorageBuffer` | In-memory write buffer with a destination table; needs to merge in-memory rows with downstream reads. |
| `StorageFile` | Local file reads; has its own virtual-column set (`_path`, `_file`, ...) handled inside the source. |
| `StorageNull` | Discards writes, returns empty reads — trivial enough not to need a base. |
| `StorageValues` | Wraps a `Block` literal as a table; used inside subquery rewrites. |
| `StorageAlias`, `StorageLoop`, `StorageFilesystem` | Specialty engines, each with non-standard semantics. |

The takeaway: deriving from `IStorage` directly is fine, but if the storage you're writing fits the "single conceptual source, wants `_table`/`_database` painted on at the plan level" pattern, prefer `StorageWithCommonVirtualColumns`. If it fits the MergeTree, cluster-table-function, or URL pattern, pick the corresponding base — those bases exist to keep the engine count manageable as the project adds more table engines.

## Quick reference: what each base class buys you

| Base | Gives you | Costs you (what you must implement) |
| --- | --- | --- |
| `IStorage` | Nothing — full freedom. | All of `read`, virtual-column registration, virtual-column materialization. |
| `StorageWithCommonVirtualColumns` | Plan-place ephemeral materialization (e.g. constant `_table`/`_database`). | `readImpl` instead of `read`; still register the virtuals. |
| `MergeTreeData` | Parts, merges, mutations, primary index, skip indices, projections, replication-ready hooks. | Engine-specific `MergingParams`; subclass to choose replicated vs single-node. |
| `IStorageCluster` | Cluster fan-out skeleton, `ReadFromCluster` step. | `getTaskIteratorExtension` to define how tasks are partitioned. |
| `IStorageURLBase` | HTTP read/write, format inference, URL virtuals. | Endpoint-specific configuration, write semantics. |
| `StorageProxy` | All capability flags and operations forwarded to a nested storage. | `getNested()` returning the real storage. |
