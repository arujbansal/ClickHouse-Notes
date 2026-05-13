# Distributed Execution and Coordination

ClickHouse scales horizontally in two orthogonal ways:

- **Sharding** splits a logical table across shards. A query is fanned out and partial results are combined on the initiator. Coordination here is *per-query* and the relevant code lives in `StorageDistributed` + `RemoteQueryExecutor`.
- **Replication** keeps multiple copies of each shard in sync. Coordination here is *persistent* and runs through Keeper (or ZooKeeper). The relevant code lives in `StorageReplicatedMergeTree` (see [04-storages-and-mergetree.md](04-storages-and-mergetree.md)) and the inter-server HTTP endpoints.

This file covers both, plus the Keeper service itself.

## Clusters

[src/Interpreters/Cluster.h](../src/Interpreters/Cluster.h) is the in-memory representation of a `remote_servers` configuration. A `Cluster` has one or more `Shard`s; each `Shard` has one or more `Replica`s (addresses with credentials). Replicas are marked as **local** when their host matches the current server — local replicas execute in-process and skip the network entirely.

`Cluster::Address` carries everything `Connection` needs: host, port, user/password, secure flag, cluster secret (for inter-server authentication), bind host. `ClusterConnectionParameters` aggregates the same fields with their defaults.

A `Cluster` is shared (immutable after construction). DNS resolution, connection pooling, and health tracking happen *outside* the cluster object — see `ConnectionPool`/`ConnectionPoolWithFailover`.

## `StorageDistributed`

[src/Storages/StorageDistributed.h](../src/Storages/StorageDistributed.h) is a *proxy* table engine. It points to (a) a cluster name and (b) a remote database + table name (which must exist on the shards). Locally it stores no data.

### Reads

`StorageDistributed::read` builds plan steps that, for each shard, create a `ReadFromRemote` step that lowers into one or more `RemoteSource` processors. Each `RemoteSource` wraps a `RemoteQueryExecutor`. The picture:

```
                  ┌──Shard1 (RemoteQueryExecutor → Connection → TCP)──┐
                  │                                                    │
SELECT  ──►  Plan ──►  ReadFromRemote(shard1) │                        │
                  ├──Shard2 (RemoteQueryExecutor → ...)────────────────┤
                  │                                                    │
                  └──Shard3 (...) ─────────────────────────────────────┘
                                          ▼
                              MergingAggregated / Sorted / Limit
                                          ▼
                                     IOutputFormat
```

The planner is aware of distribution. For a `GROUP BY`, it splits work into two stages:

- **Partial aggregation on shards.** The remote query is rewritten to include `WITH TOTALS` / `GROUP BY` and the shard returns *states*, not finalized values. The state shipping uses the same `-State`/`-Merge` machinery as `AggregatingMergeTree`.
- **Final aggregation on initiator.** A `MergingAggregatedTransform` combines shard states.

Similarly for `ORDER BY` (`partial → final` sort+merge), `DISTINCT`, `LIMIT BY`. Most of the planning logic is in [src/Storages/buildQueryTreeForShard.cpp](../src/Storages/buildQueryTreeForShard.cpp) and the per-step `ReadFromRemote` lowering.

### Writes (sync and async)

`INSERT INTO distributed_table` can take one of two paths:

1. **Synchronous** (`insert_distributed_sync = 1`). Rows are split by sharding key on the initiator and pushed to each shard immediately over native protocol.
2. **Async, the default.** Rows are written to per-shard subdirectories under the table's local data dir (one `.bin` file per failed-or-pending block per shard). A background `DistributedAsyncInsertDirectoryQueue` ([src/Storages/Distributed/DistributedAsyncInsertDirectoryQueue.h](../src/Storages/Distributed/DistributedAsyncInsertDirectoryQueue.h)) drains them. This buffers inserts when shards are slow or unreachable, at the cost of weaker durability (the local disk is the source of truth until drained).

The **sharding key** is an arbitrary expression (typically `cityHash64(user_id)`); modulo the sum of shard weights it picks the destination shard.

### `RemoteQueryExecutor`

[src/QueryPipeline/RemoteQueryExecutor.h](../src/QueryPipeline/RemoteQueryExecutor.h) is the workhorse for remote-side execution. It:

1. Opens a `Connection` (from the pool with failover).
2. Sends `query`, current `Settings`, scalars, prepared sets, external tables, and the originator's user context.
3. Reads back `Data` packets (`Native`-format blocks) and turns them into `Chunk`s for the local pipeline.
4. Also handles `Progress`, `Exception`, `Log`, `ProfileInfo` packets.

It supports a few advanced modes:

- **Task iterators.** For `s3Cluster`-style queries, the initiator hands out work (file globs) to shards on demand. Each shard pulls the next task; this is how dynamic load balancing of object-storage reads happens.
- **Parallel replicas.** If `allow_experimental_parallel_reading_from_replicas` is set, multiple replicas of the same shard cooperate on one query — the initiator coordinates which mark ranges each replica should read, and `RemoteQueryExecutor` becomes a coordinated source instead of an independent one.

### `Connection`

[src/Client/Connection.h](../src/Client/Connection.h) is the native-protocol client. It speaks the same TCP wire format that `clickhouse-client` uses (`CompressedReadBuffer`/`CompressedWriteBuffer` over the socket; LZ4 by default; ZSTD optional). Packet types are defined in [src/Core/Protocol.h](../src/Core/Protocol.h).

The pool layer (`ConnectionPool`, `ConnectionPoolWithFailover`) caches connections, applies hedged requests / health-based failover, and re-uses keep-alive sockets.

## Inter-server HTTP: replication transport

Replication doesn't use the native protocol — it uses HTTP between servers (often on a separate `interserver_http_port` and `interserver_http_credentials`). The dispatch lives in [src/Interpreters/InterserverIOHandler.h](../src/Interpreters/InterserverIOHandler.h): an `InterserverIOEndpoint` interface plus a registry indexed by URL path.

The two main endpoints:

- **`DataPartsExchange::Service`** ([src/Storages/MergeTree/DataPartsExchange.h](../src/Storages/MergeTree/DataPartsExchange.h)) — serves parts. When replica B needs a part replica A produced, B sends an HTTP GET with the part name; A streams the part directory contents (column `.bin`, `.mrk`, indexes, checksums) back.
- **`DataPartsExchange::Fetcher`** — the client side. Downloads the part into a `tmp_<name>/` directory, verifies checksums, and renames into place.

Replication is fundamentally "ship parts; replay a log of merge/mutation decisions." The log lives in Keeper, the parts ride over HTTP.

## ClickHouse Keeper

ClickHouse ships a built-in coordination service compatible with the ZooKeeper wire protocol but built on Raft (NuRaft). It's in [src/Coordination/](../src/Coordination/). You can either point ClickHouse at an external ZooKeeper ensemble or run Keeper embedded in the ClickHouse binary or as a standalone `clickhouse-keeper` process.

Key files:

- [src/Coordination/KeeperServer.h](../src/Coordination/KeeperServer.h) — wraps NuRaft. Manages the Raft state, log, and cluster membership.
- [src/Coordination/KeeperStateMachine.h](../src/Coordination/KeeperStateMachine.h) — implements `nuraft::state_machine`. Holds the actual key-value tree (ZooKeeper-style hierarchical znodes with watches, ephemerals, sequential creates) and applies committed Raft entries.
- [src/Coordination/KeeperStorage.h](../src/Coordination/KeeperStorage.h) — the in-memory storage backing the state machine.
- [src/Coordination/KeeperSnapshotManager.h](../src/Coordination/KeeperSnapshotManager.h) — periodic full snapshots so Raft logs can be truncated. Snapshots can be stored on local disk and/or S3.

What ClickHouse uses Keeper for:

| Use | Keeper paths |
| --- | --- |
| ReplicatedMergeTree coordination | `/clickhouse/tables/<shard>/<table>/log`, `/replicas/<replica>/queue`, `/parts`, `/block_numbers`, `/columns`, `/mutations`, ... |
| `ON CLUSTER` DDL | `/clickhouse/task_queue/ddl/` — global queue of DDL entries; each server applies entries in order and reports results. |
| Replicated databases | `DatabaseReplicated` — the database schema itself is in Keeper, every DDL is logged. |
| Distributed DDL lock, distributed coordination of long operations (mutation status, etc.) | Various. |
| `s3Queue` engine | Atomic claim of S3 files for ingestion. |

Why a custom Raft-based service instead of using ZooKeeper? Operational simplicity (one binary, no JVM), tighter integration (snapshot to S3 like everything else, native metrics), and the ability to ship behavior changes alongside ClickHouse releases.

## Putting the distributed picture together

A `SELECT count() FROM distributed_replicated_table WHERE date = today() GROUP BY user_id`:

1. **Initiator.** `StorageDistributed::read` plans one `ReadFromRemote` per shard.
2. **Per-shard plan.** The initiator rewrites the query to do *partial* aggregation: `SELECT user_id, countState() FROM local_replicated_table WHERE date = today() GROUP BY user_id`. `RemoteQueryExecutor` ships this to a healthy replica of each shard.
3. **On each replica.** Standard local execution against `StorageReplicatedMergeTree` (which is a `MergeTreeData` under the hood). Keeper is involved only because the replica needs the current part set — but the *query* doesn't hit Keeper at all; it reads parts that have already been committed.
4. **Back to initiator.** Each shard streams partial state chunks over native protocol.
5. **Merge stage.** `MergingAggregatedTransform` merges the states; an outer `ExpressionStep` runs `countMerge` to produce final counts.
6. **Format and reply.** As usual.

Replication and sharding don't interact at query time. Replication is what makes "a healthy replica" available in step 2. The two systems are layered cleanly, which is why you can run ClickHouse with replication-only, sharding-only, or both.

## Failure modes and where they show up

- **Slow shard / replica.** `ConnectionPoolWithFailover` and **hedged requests** (`use_hedged_requests`) issue a second request to a different replica after a delay; whichever responds first wins.
- **Unreachable shard during INSERT.** Async-insert path buffers to disk; sync-insert path errors. The buffered `.bin` files in the distributed directory are visible in `system.distribution_queue`.
- **Replica falls behind.** It appears in `system.replication_queue` with the queue length growing. Operationally: check Keeper health, check disk space, check fetch speed.
- **Keeper outage.** Replicated tables become read-only (`is_readonly = 1` in `system.replicas`). Reads continue (parts on disk are fine); writes and merges block. This is why Keeper sizing/HA matters.
