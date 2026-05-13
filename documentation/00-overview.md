# ClickHouse Architecture: Overview

This folder contains contributor-oriented architecture documentation for ClickHouse. It complements (and goes deeper than) the official page at <https://clickhouse.com/docs/development/architecture>. Each file dives into one subsystem; this overview ties them together and shows how a query flows end-to-end.

## How to read this

If you are new, read this file first, then [01-core-data-model.md](01-core-data-model.md) (the abstractions everyone else assumes). From there, the rest can be read in any order:

| File | What it covers |
| --- | --- |
| [01-core-data-model.md](01-core-data-model.md) | `IColumn`, `IDataType`, `Field`, `Block`, `Chunk` — the in-memory representation of data |
| [02-query-frontend.md](02-query-frontend.md) | SQL string → AST → QueryTree → QueryPlan → Interpreter |
| [03-processors-and-pipeline.md](03-processors-and-pipeline.md) | `IProcessor`, ports, `QueryPipeline`, `PipelineExecutor` — vectorized execution model |
| [04-storages-and-mergetree.md](04-storages-and-mergetree.md) | `IStorage`, the MergeTree family, parts/granules/marks, replication |
| [05-functions.md](05-functions.md) | Ordinary, aggregate, and table functions; `ActionsDAG`; JIT |
| [06-io-and-formats.md](06-io-and-formats.md) | `ReadBuffer`/`WriteBuffer`, input/output formats |
| [07-distributed-and-coordination.md](07-distributed-and-coordination.md) | `StorageDistributed`, `RemoteQueryExecutor`, Keeper, replication transport |
| [08-server-and-context.md](08-server-and-context.md) | Server bootstrap, protocol handlers, the `Context` object |
| [09-istorage-hierarchy.md](09-istorage-hierarchy.md) | The `IStorage` class hierarchy: intermediate bases (`StorageWithCommonVirtualColumns`, `MergeTreeData`, `IStorageCluster`, `IStorageURLBase`, `StorageProxy`) and why each exists |

## The single most important sentence

ClickHouse is a **vectorized, columnar, MPP analytic DBMS** in which:

- Data is stored and processed as **columns**, not rows.
- Operations are dispatched **per-batch** (a `Chunk` of typically 65k rows), not per-row, so each virtual call amortizes over thousands of values and inner loops are SIMD-friendly.
- Execution is a **graph of `IProcessor` nodes** scheduled on a thread pool, not a recursive `next()`-style iterator tree.
- The on-disk storage of choice — the **`MergeTree` family** — writes **immutable parts** and merges them in the background. There is no in-place UPDATE; mutations rewrite parts. This is why replication is conflict-free.

Almost every other design choice in the codebase follows from those four.

## End-to-end life of a query

Trace a `SELECT count() FROM hits WHERE url LIKE '%example%'` from the client socket down to disk and back. File pointers reference the entry points in each subsystem; the per-subsystem docs expand each step.

### 1. Network → handler

A client connects on TCP (native protocol) or HTTP. The corresponding handler runs in the server's connection-accepting thread pool.

- [src/Server/TCPHandler.cpp](../../src/Server/TCPHandler.cpp) — native protocol; the main path for `clickhouse-client` and inter-server traffic
- [src/Server/HTTPHandler.h](../../src/Server/HTTPHandler.h) — REST-style `?query=...`
- [src/Server/MySQLHandler.h](../../src/Server/MySQLHandler.h), [src/Server/PostgreSQLHandler.h](../../src/Server/PostgreSQLHandler.h) — wire-compat shims

The handler reads the query string and arguments, attaches a `Session` and a per-query `Context`, and calls the universal entry point:

- [src/Interpreters/executeQuery.cpp](../../src/Interpreters/executeQuery.cpp) — `executeQuery` / `executeQueryImpl`

See [08-server-and-context.md](08-server-and-context.md).

### 2. Parse: SQL → AST

`executeQueryImpl` invokes `parseQuery` ([src/Parsers/parseQuery.h](../../src/Parsers/parseQuery.h)), which tokenizes the input and runs a hand-written recursive-descent parser, `ParserQuery` ([src/Parsers/ParserQuery.h](../../src/Parsers/ParserQuery.h)). The result is an `IAST` tree of nodes like `ASTSelectQuery`, `ASTFunction`, `ASTIdentifier` ([src/Parsers/IAST.h](../../src/Parsers/IAST.h)). The AST captures syntax only — identifiers are unresolved strings.

See [02-query-frontend.md](02-query-frontend.md).

### 3. Analyze: AST → QueryTree

For `SELECT`, the **new analyzer** (the legacy `ExpressionAnalyzer` still exists for compatibility) takes over. `QueryTreeBuilder` ([src/Analyzer/QueryTreeBuilder.h](../../src/Analyzer/QueryTreeBuilder.h)) lifts the AST into a `QueryTree` of `IQueryTreeNode`s ([src/Analyzer/IQueryTreeNode.h](../../src/Analyzer/IQueryTreeNode.h)) and then runs ~30 semantic passes, the central one being `QueryAnalysisPass` ([src/Analyzer/Passes/QueryAnalysisPass.h](../../src/Analyzer/Passes/QueryAnalysisPass.h)). After analysis, every identifier resolves to a concrete column/table/function, every expression has a known type, constants are folded, and rewrites like `CROSS → INNER JOIN` have run.

### 4. Plan: QueryTree → QueryPlan

The `Planner` ([src/Planner/Planner.h](../../src/Planner/Planner.h)) walks the QueryTree and emits a logical `QueryPlan` ([src/Processors/QueryPlan/QueryPlan.h](../../src/Processors/QueryPlan/QueryPlan.h)) — a tree of `IQueryPlanStep` nodes (`ReadFromMergeTree`, `FilterStep`, `ExpressionStep`, `AggregatingStep`, ...). Three waves of optimizations run over the plan ([src/Processors/QueryPlan/Optimizations/Optimizations.h](../../src/Processors/QueryPlan/Optimizations/Optimizations.h)): filter pushdown, PREWHERE conversion, read-in-order, primary-key range narrowing, and so on.

### 5. Lower: QueryPlan → QueryPipeline

Each step calls `IQueryPlanStep::updatePipeline` to add concrete `IProcessor`s to a `QueryPipelineBuilder` ([src/QueryPipeline/QueryPipelineBuilder.h](../../src/QueryPipeline/QueryPipelineBuilder.h)). The result is a `QueryPipeline` ([src/QueryPipeline/QueryPipeline.h](../../src/QueryPipeline/QueryPipeline.h)): a graph whose leaves are sources (typically `MergeTreeSelectProcessor`), whose interior nodes are transforms (`ExpressionTransform`, `FilterTransform`, `AggregatingTransform`, `MergingSortedTransform`, ...), and whose root is the format output.

### 6. Read: storage produces chunks

For our `hits` table, the source processors come from `MergeTreeDataSelectExecutor::read` ([src/Storages/MergeTree/MergeTreeDataSelectExecutor.h](../../src/Storages/MergeTree/MergeTreeDataSelectExecutor.h)). It:

1. Prunes parts by partition key.
2. Uses the **sparse primary index** to compute mark ranges intersecting the WHERE.
3. Applies skip indices (minmax, bloom, set, ...) and projections.
4. Builds parallel reading streams over the selected `MarkRange`s.

Data on disk lives in **immutable parts** ([src/Storages/MergeTree/IMergeTreeDataPart.h](../../src/Storages/MergeTree/IMergeTreeDataPart.h)) with `.bin` (compressed column data) and `.mrk` (offsets into `.bin`) files. Reads go through `ReadBuffer` ([src/IO/ReadBuffer.h](../../src/IO/ReadBuffer.h)), wrapped in `CompressedReadBuffer` ([src/Compression/CompressedReadBuffer.h](../../src/Compression/CompressedReadBuffer.h)).

See [04-storages-and-mergetree.md](04-storages-and-mergetree.md) and [06-io-and-formats.md](06-io-and-formats.md).

### 7. Execute: PipelineExecutor

The handler wraps the pipeline in a `PullingPipelineExecutor` ([src/Processors/Executors/PullingPipelineExecutor.h](../../src/Processors/Executors/PullingPipelineExecutor.h)) and calls `pull(chunk)` in a loop. Internally the `PipelineExecutor` ([src/Processors/Executors/PipelineExecutor.h](../../src/Processors/Executors/PipelineExecutor.h)) walks an `ExecutingGraph`, calling each processor's split `prepare()` (cheap, port-state-only, serialized) / `work()` (CPU-bound, parallel) state-machine pair. Async sources (S3, network) yield via `schedule()` and resume on epoll readiness.

See [03-processors-and-pipeline.md](03-processors-and-pipeline.md).

### 8. Compute: vectorized work

`FilterTransform` runs the WHERE: it calls into an `ActionsDAG` ([src/Interpreters/ActionsDAG.h](../../src/Interpreters/ActionsDAG.h)) of compiled expression nodes; the `LIKE` is an `IExecutableFunction` ([src/Functions/IFunction.h](../../src/Functions/IFunction.h)) acting on an entire `IColumn` of strings ([src/Columns/IColumn.h](../../src/Columns/IColumn.h)) at once. `AggregatingTransform` then maintains aggregate states ([src/AggregateFunctions/IAggregateFunction.h](../../src/AggregateFunctions/IAggregateFunction.h)) in an `Arena`-backed hash table.

See [05-functions.md](05-functions.md).

### 9. Format and send

The pipeline ends in an `IOutputFormat` ([src/Processors/IOutputFormat.h](../../src/Processors/Formats/IOutputFormat.h)) chosen by the client (`Native`, `JSONEachRow`, `Pretty`, ...) writing into a `WriteBuffer` connected to the socket.

### 10. Distributed variant

If `hits` were a `StorageDistributed` ([src/Storages/StorageDistributed.h](../../src/Storages/StorageDistributed.h)), step 6 would instead instantiate one `RemoteQueryExecutor` ([src/QueryPipeline/RemoteQueryExecutor.h](../../src/QueryPipeline/RemoteQueryExecutor.h)) per shard. Each one opens a native-protocol `Connection` ([src/Client/Connection.h](../../src/Client/Connection.h)) to a remote replica, ships the rewritten subquery, and receives `Native`-format blocks that feed the local pipeline as if they were sources. Aggregation is split into partial (remote) and final (initiator) stages.

See [07-distributed-and-coordination.md](07-distributed-and-coordination.md).

## Why these abstractions, in one paragraph each

**Columns and Chunks.** Per-row dispatch is dominated by virtual-call and branch-mispredict overhead. By making the unit of work a column of ~65k values with a known type, every hot loop is straight-line, branchless, and SIMD-vectorizable. `Chunk` is `Block` without the names — used inside pipelines where schema is already implied by the plan.

**Copy-on-Write columns.** Pipelines share `ColumnPtr`s across processors; without immutability we'd need locks or copies. COW (`IColumn` inherits from `COW<IColumn>`) gives free sharing of read-only columns and in-place reuse when an owner is unique.

**Processors with prepare/work split.** Old block streams pulled recursively, which forces lock-stepped execution and tangles I/O with compute. The processor model decouples *port state transitions* (cheap, single-threaded, in `prepare`) from *compute* (parallel, in `work`) and *I/O* (yielded via `schedule`/`Async`). The scheduler can then run many processors over many cores while keeping coordination lock-free.

**MergeTree's immutable parts.** Random writes ruin compression and indexing. By making writes append-only at the part level and merging parts in the background, ClickHouse keeps each part densely sorted and densely compressed, and replication reduces to "ship parts and replay a small log of merge decisions" — no row-level conflict resolution is ever needed.

**Sparse primary index.** A B-tree per row would be larger than the data. The sparse index instead records one key per `index_granularity` (default 8192) rows; this is small enough to live in memory and precise enough to prune most of the parts on selective predicates, with the per-granule scan covering the rest.

**`Context` everywhere.** Settings, the database catalog, access control, caches, and per-query state all need to be reachable from any layer — parser, planner, function, storage. Rather than threading them as parameters, ClickHouse uses a shared/per-query `Context` ([src/Interpreters/Context.h](../../src/Interpreters/Context.h)). Subqueries and distributed fragments get `Context::createCopy` snapshots.

## A simplified call graph

```
client socket
   │
   ▼
TCPHandler / HTTPHandler                          [08-server-and-context.md]
   │   (creates per-query Context)
   ▼
executeQuery ──► parseQuery ──► IAST              [02-query-frontend.md]
   │                                  │
   │                                  ▼
   │                            QueryTreeBuilder + passes   (Analyzer)
   │                                  │
   │                                  ▼
   │                              Planner
   │                                  │
   │                                  ▼
   │                              QueryPlan + optimizations
   │                                  │
   │                                  ▼
   │                          QueryPipelineBuilder           [03-processors-and-pipeline.md]
   │                                  │
   │                                  ▼
   │                           QueryPipeline (IProcessor graph)
   │                              ▲       ▲
   │                              │       │
   │                          sources   transforms
   │   ┌──────────────────────────┘       │
   │   ▼                                  ▼
   │ IStorage::read   ◄── IDataType / IColumn / Chunk    [01-core-data-model.md]
   │   │       (MergeTree, Distributed, ...)             [04-storages-and-mergetree.md]
   │   │                                                 [07-distributed-and-coordination.md]
   │   ▼
   │ ReadBuffer hierarchy (file / S3 / compressed)       [06-io-and-formats.md]
   │
   ▼
PullingPipelineExecutor.pull(chunk)
   │
   ▼
IOutputFormat ──► WriteBuffer ──► client socket
```

The rest of the docs zoom into each box.
