# Storages and MergeTree

A **storage** (a.k.a. table engine) is the interface between the SQL execution engine and physical/external data. The default and dominant family is **MergeTree**, which is what makes ClickHouse fast for analytic queries on disk-resident data. This file covers the `IStorage` interface, the table-engine families, and a deeper look at MergeTree.

## `IStorage`: the table engine interface

[src/Storages/IStorage.h](../../src/Storages/IStorage.h) is the contract every engine implements. For a deeper look at the intermediate base classes below `IStorage` (`StorageWithCommonVirtualColumns`, `MergeTreeData`, `IStorageCluster`, `IStorageURLBase`, `StorageProxy`) and the virtual-column machinery they wire up, see [09-istorage-hierarchy.md](09-istorage-hierarchy.md).

Core methods:

| Method | Purpose |
| --- | --- |
| `read(query_plan, ...)` | Append a source step to a `QueryPlan` that will produce rows from this table. |
| `write(query, metadata, ...)` | Return a `SinkToStorage` that consumes rows for `INSERT`. |
| `alter(commands, ...)` | Apply `AlterCommands` (ADD/DROP/MODIFY column, MOVE PARTITION, ...). |
| `mutate(commands, ...)` | Apply `MutationCommands` (UPDATE/DELETE, recompute materialized columns). |
| `optimize(...)`, `drop()`, `truncate()`, `rename()` | What they say. |
| `getInMemoryMetadataPtr()` | Returns the current `StorageInMemoryMetadata` (columns, keys, indices, TTLs, projections, settings). |
| `supportsX()` family | Capability flags the planner queries: `supportsSampling`, `supportsPrewhere`, `supportsReplication`, `supportsTTL`, `supportsParallelInsert`, ... |

Key design points:

- **`StorageMetadataPtr` is multi-versioned and immutable per version.** Concurrent readers and writers never need to lock metadata; they each carry a snapshot pointer. ALTERs swap the version atomically.
- **`StorageSnapshot`** ([src/Storages/StorageSnapshot.h](../../src/Storages/StorageSnapshot.h)) freezes both metadata *and* engine-specific runtime data (for MergeTree: the active parts list) at the moment a query starts. The whole query reads against that snapshot — new merges or inserts that happen mid-query are invisible to it.
- **`read()` produces plan steps, not pipelines.** This lets QueryPlan-level optimizations (PREWHERE, read-in-order, primary-key narrowing) work *across* the storage boundary.

## Engine families

A non-exhaustive map of `src/Storages/`:

**MergeTree family.** The production OLAP storage. All variants share `MergeTreeData` ([src/Storages/MergeTree/MergeTreeData.h](../../src/Storages/MergeTree/MergeTreeData.h)).

| Engine | Variation |
| --- | --- |
| `MergeTree` | Plain. |
| `ReplacingMergeTree` | Background merges deduplicate on the sorting key (latest version wins). |
| `SummingMergeTree` | Merges sum numeric columns with the same sorting key. |
| `AggregatingMergeTree` | Merges combine aggregate-function states. |
| `CollapsingMergeTree`, `VersionedCollapsingMergeTree` | Row-level deletes via a sign column. |
| `GraphiteMergeTree` | Roll-up for Graphite metrics. |
| `Replicated*MergeTree` | Any of the above plus Keeper-coordinated replication. |

**Log family.** TinyLog / Log / StripeLog. Append-only, no indices, single file or one-file-per-column. Useful for small append-only tables; not for analytics at scale.

**Integration engines.** Talk to external data sources, often without copying data in: `StorageS3` / `StorageS3Queue`, `StorageURL`, `StorageFile`, `StorageHDFS`, `StorageMySQL` / `StoragePostgreSQL` / `StorageMongoDB`, `StorageKafka` / `StorageRabbitMQ` / `StorageNATS`, `StorageDeltaLake` / `StorageIceberg` / `StorageHudi`.

**Composite / special.** `StorageDistributed` (fan-out wrapper, see [07-distributed-and-coordination.md](07-distributed-and-coordination.md)), `StorageMerge` (`SELECT` over a regex-matched set of tables), `StorageView` / `StorageMaterializedView`, `StorageMemory`, `StorageNull` (the `/dev/null` of table engines), `StorageBuffer` (in-memory write buffer flushed to a destination), `StorageDictionary` (table view of a dictionary).

## `DatabaseCatalog`

[src/Interpreters/DatabaseCatalog.h](../../src/Interpreters/DatabaseCatalog.h) is the registry that resolves `(database, table)` → `StoragePtr`. Tables live inside `IDatabase` objects ([src/Databases/IDatabase.h](../../src/Databases/IDatabase.h)); the most common database engine is `DatabaseAtomic`, which uses `RENAME` of metadata files for crash-safe DROP. Notable built-in databases: `system` (introspection tables), `information_schema` (SQL standard views), `_temporary_and_external_tables` (per-session scratch).

DDL serializes on a per-table `DDLGuard` taken from the catalog to prevent concurrent CREATE/DROP/RENAME from racing.

## MergeTree, in depth

### Parts: the unit of storage

A MergeTree table is **a directory of immutable parts**. Each part is itself a directory under `<table_path>/data/<partition_id>/<part_name>/`. The naming scheme (encoded in [src/Storages/MergeTree/MergeTreePartInfo.h](../../src/Storages/MergeTree/MergeTreePartInfo.h)):

```
<partition_id>_<min_block>_<max_block>_<level>[_<mutation_version>]
```

- `partition_id` — value of the partition expression (e.g. `20240115` for daily partitioning by date).
- `min_block` / `max_block` — block-number range (each `INSERT` gets a fresh block number; merges fold ranges).
- `level` — merge generation (an unmerged INSERT is level 0; merging level-0 parts produces level 1; etc.).
- `mutation_version` — bumped when a mutation rewrites the part.

A typical part directory contains:

| File | Role |
| --- | --- |
| `columns.txt` | Column names and types in this part (may differ from table schema during ALTER). |
| `primary.idx` | The **sparse primary index**: one row per granule. |
| `<col>.bin` | Compressed column data. |
| `<col>.mrk2` / `.cmrk2` | "Mark" files: byte offsets into `.bin` for each granule's start. `.mrk2` is the uncompressed v2 format; `.cmrk2` is the same content with the file itself compressed (`compress_marks` MergeTree setting, on by default). Older parts may still have `.mrk` (v1) format. Each mark is *two* offsets, not one — see below. |
| `partition.dat`, `minmax_<col>.idx` | Partition expression values and per-column min/max for fast partition pruning. |
| `skp_idx_<name>.idx` | Skip indices (minmax, set, bloom_filter, ngrambf_v1, ...). |
| `checksums.txt` | CRC of every file; verified at part load. |
| `count.txt` | Row count (so `SELECT count()` doesn't need to read columns). |

**Parts are immutable.** Nothing modifies a part after it's committed. Updates produce a new part with a higher mutation version; merges produce a new part covering a wider block range. Old parts are deleted asynchronously once no query holds a reference.

### Granules, marks, and the sparse primary index

The most important MergeTree design choice. Rows in a part are conceptually divided into **granules** of `index_granularity` rows (default 8192). The primary index stores **one entry per granule** — typically the value of the sorting key at the granule's first row. So an 8 billion-row table has only ~1 million index entries: small enough to keep in memory, large enough to be useful.

When a query has a predicate on a sorting-key prefix (`WHERE event_date = ...`, `WHERE user_id IN ...`), the primary index lets ClickHouse identify the *granule ranges* (`MarkRange`s) that *could* match. For everything else, it scans those granules linearly. This is dramatically cheaper to maintain than a dense per-row B-tree, and for analytic workloads (selective on a few columns, scanning a lot of data) it's nearly as effective.

`.mrk2` mark files map granule index → byte offset in the compressed `.bin` so a reader can `seek` directly to the start of a granule without decompressing everything before it. Each mark has *two* offsets: the compressed block start and the uncompressed offset within that block — so granules don't need to be block-aligned.

### Selecting parts and granules: `MergeTreeDataSelectExecutor`

[src/Storages/MergeTree/MergeTreeDataSelectExecutor.h](../../src/Storages/MergeTree/MergeTreeDataSelectExecutor.h) is what `MergeTreeData::read` ultimately calls. Roughly, it:

1. **Snapshot the active parts.** From the `StorageSnapshot`.
2. **Partition pruning.** Use the partition key + `minmax_<col>` indices to discard whole parts.
3. **Primary key range selection** (`markRangesFromPKRange`). Convert the WHERE clause into a `KeyCondition` and binary-search the sparse index for the matching `MarkRange`s.
4. **Skip-index filtering** (`filterMarksUsingIndex`). Per-granule bloom filter / minmax / set tests further trim the mark ranges.
5. **Projection selection.** If a projection covers the query better than the base table, swap to it.
6. **Stream construction.** Split the surviving (part, mark range) tasks across `max_threads` streams; each stream becomes a `MergeTreeSelectProcessor` source in the pipeline. `PREWHERE` runs inside the source so unselected rows never materialize the rest of the columns.

The thing to understand: **after this point, the rest of the pipeline doesn't know it's reading MergeTree.** It's just chunks coming out of source processors. All MergeTree-specific knowledge — granule iteration, mark file lookup, skip indices, PREWHERE — lives inside the source.

### Skip indices and projections

- **Skip indices** ([src/Storages/MergeTree/MergeTreeIndices.h](../../src/Storages/MergeTree/MergeTreeIndices.h)) are *coarse-grained* per-granule (or per-N-granule) digests: bloom filter for equality, minmax for range, set for cardinality-bounded sets, ngrambf for substring. They prune granules; they never produce false negatives, but they can have false positives.
- **Projections** are alternative materializations of the table (different sorting key, pre-aggregated, etc.) stored *inside* each part. The planner can transparently rewrite a query to read from a projection if it'd cover the predicates better. They're updated atomically with the part because they're part of the part.

### Writing: temp parts → committed parts

The write path goes through `MergeTreeDataWriter` ([src/Storages/MergeTree/MergeTreeDataWriter.h](../../src/Storages/MergeTree/MergeTreeDataWriter.h)):

1. `splitBlockIntoParts` — partition the incoming `Block` by the partition expression. Each output piece will become one part.
2. `writeTempPart` — serialize columns into a `tmp_<part_name>/` directory (compressed `.bin`s, marks, indices, checksums). The directory name starts with `tmp_` so a crash mid-write leaves orphans that startup cleans up.
3. **Atomic rename** — on success the directory is renamed to its final name and added to the active parts set under the data-parts mutex.

Inserts are not append-to-file; each one creates a new part. Many small inserts → many small parts → slow reads. Tune your client to batch (or use async inserts / `Buffer` engine / `Distributed` async).

### Background work: merges, mutations, TTL

`MergeTreeBackgroundExecutor` ([src/Storages/MergeTree/MergeTreeBackgroundExecutor.h](../../src/Storages/MergeTree/MergeTreeBackgroundExecutor.h)) runs background tasks on a priority queue. Tasks are executed *step by step* (each `executeStep()` does a bounded chunk of work and re-queues) so a long merge never monopolizes a thread.

Task kinds:

- **Merges** (`MergeTask`). The merge selector ([src/Storages/MergeTree/MergeSelectors/](../../src/Storages/MergeTree/Compaction/MergeSelectors/)) periodically picks adjacent parts to merge based on size/age heuristics, producing larger sorted parts and shrinking the active set. For `*ReplacingMergeTree` / `*SummingMergeTree` / etc., this is also where row-level dedup/aggregation happens.
- **Mutations** (`MutateTask`). `ALTER TABLE ... UPDATE/DELETE/MODIFY COLUMN` is implemented by rewriting each part. The mutation entry assigns a *mutation version*; replicas converge by applying the same entries in the same order. Until a part is mutated, reads apply the predicate at query time (a "lightweight" delete or update).
- **TTL** (`TTLMergeTask`). Drop expired rows or move parts between disks/volumes.
- **Outdated-part removal.** Once no query references an old (pre-merge) part, it's deleted.

### Replicated MergeTree

`StorageReplicatedMergeTree` ([src/Storages/StorageReplicatedMergeTree.h](../../src/Storages/StorageReplicatedMergeTree.h)) layers replication on top of MergeTree using **ClickHouse Keeper / ZooKeeper** ([src/Coordination/](../../src/Coordination/), see [07-distributed-and-coordination.md](07-distributed-and-coordination.md)) as the coordination plane.

The model is **leaderless**:

- All replicas share a **replication log** in Keeper at `/clickhouse/tables/<shard>/<table>/log/`. Entries are typed: `GET_PART` (fetch a part from another replica), `MERGE_PARTS`, `MUTATE_PART`, `ALTER_METADATA`, `DROP_RANGE`.
- Each replica has its own **queue** (`/replicas/<replica>/queue/`) populated by tailing the log and translating entries into local tasks. `ReplicatedMergeTreeQueue` ([src/Storages/MergeTree/ReplicatedMergeTreeQueue.h](../../src/Storages/MergeTree/ReplicatedMergeTreeQueue.h)) tracks the queue and the **virtual parts** invariant: `virtual_parts = current_parts ∪ queue`. That set is what the replica's data will look like once it's caught up; new merge proposals only operate on virtual parts.
- An INSERT on any replica: the inserter creates the part locally, writes a `GET_PART` entry to the log, and lets other replicas fetch the part over HTTP (`InterserverIOHandler`, see [07-distributed-and-coordination.md](07-distributed-and-coordination.md)).
- Merges and mutations: any replica can propose them; whichever node's proposal gets accepted into the log first becomes the canonical decision. Other replicas execute the same merge locally (cheaper) or download the merged part (when local merge isn't feasible).

**Why this is conflict-free.** There are no row-level updates. Every state change is either (a) a fresh part introduced under a new block number, or (b) a deterministic merge/mutation of existing parts. Keeper linearizes the log; the deterministic transformations applied in log order make every replica converge to the same data. There is no "last write wins" because there are no overwriting writes.

### Mutations as versioned operations

`ALTER TABLE ... DELETE / UPDATE` is `mutate()` ([src/Storages/MergeTree/MutateTask.h](../../src/Storages/MergeTree/MutateTask.h)). The mutation is registered (`system.mutations` shows progress) and each part gets rewritten with the mutation's effect applied. Until rewrite, reads transparently apply the predicate. `ALTER TABLE ... DELETE WHERE` therefore is **eventually consistent within the replica**, not instantaneous — and rewriting every affected part can be expensive on a wide table.

**Lightweight deletes** (`DELETE FROM table WHERE ...`) are the fast alternative. They write a single new part containing only the persistent virtual column `_row_exists` (`UInt8`, `1` = alive, `0` = deleted) for the affected rows. Subsequent reads `AND` `_row_exists` into the row mask before materializing other columns, so deleted rows are filtered without rewriting anything else. The "real" delete (rewriting the parts to remove the rows) happens lazily during the next merge, which folds `_row_exists` into the row set being copied. This makes `DELETE` fast and merges modestly slower; the trade-off is usually a win because deletes are bursty while merges are continuous.

Lightweight updates (`UPDATE ... SET col = expr`) work analogously: instead of rewriting affected parts, the engine writes a **patch part** containing the new values plus the row ids it patches, and reads splice these patch parts on top of the base part. The `apply_patch_parts` setting (default on) controls whether selects apply pending patches; merges eventually fold patches into the base parts so the patch chain stays bounded. The patch-part machinery lives under [src/Storages/MergeTree/PatchParts/](../../src/Storages/MergeTree/PatchParts/).

## Invariants worth memorizing

1. **Parts are immutable.** If you find yourself wanting to modify a part on disk, you almost certainly want to produce a new part instead.
2. **Replication is conflict-free because there are no UPDATEs.** All state transitions are deterministic transformations of immutable parts.
3. **Metadata is multi-versioned and lock-free for readers.** Don't add a mutex to `StorageInMemoryMetadata`.
4. **`StorageSnapshot` defines a query's view of the world.** Don't read live data outside the snapshot; you'll race with merges.
5. **The sparse primary index is the key to MergeTree's read performance.** If a query is slow on a MergeTree table, the first question is: did the primary key prune anything? `EXPLAIN indexes = 1` answers it.
