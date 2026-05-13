# Server Lifecycle, Protocol Handlers, and `Context`

This file covers the outer ring: how a `clickhouse-server` process starts up, how connections get turned into queries, and how `Context` threads global and per-query state through every layer.

## Process startup

The server entry point is [programs/server/Server.cpp](../../programs/server/Server.cpp), which is a few thousand lines of mostly initialization. The high-level startup sequence:

1. **Daemon bootstrap.** [src/Daemon/BaseDaemon.h](../../src/Daemon/BaseDaemon.h) sets up signal handlers, the crash signal handler that writes a backtrace via libunwind, logging, and the PID file.
2. **Logger.** Poco-based logger configured from `<logger>` section of `config.xml`.
3. **Configuration.** Loads `config.xml` plus `config.d/*.xml`, `users.xml` plus `users.d/*.xml`, with includes and ZooKeeper-served overrides. The result is the runtime config tree consulted everywhere.
4. **Global `Context`.** `Context::createGlobal(shared_part)` creates the process-wide `Context`. From this point on, every subsystem registers into the shared part.
5. **Subsystem registration.** Functions, aggregate functions, table functions, table engines, format factories, dictionary sources, disk types — all registered via singleton factories (look for `register*()` calls in `Server.cpp`).
6. **Storage system bring-up.** `system.*` tables, `information_schema`, the `_temporary_and_external_tables` database. Then loading user databases from on-disk metadata in `metadata/<db>/<table>.sql`.
7. **Thread pools.** Global pool, IO pool, background merges pool, background fetches pool, async insert pool, BACKUP pool. Sizes from `background_pool_size` family of settings.
8. **Caches.** Mark cache, uncompressed cache, query result cache, query condition cache, MMapped files cache, compiled-expression cache. Sized from config.
9. **Protocol listeners.** TCP (native, secure variant), HTTP / HTTPS, MySQL, PostgreSQL, gRPC, Inter-server HTTP, Prometheus, optionally Keeper. Each binds to its configured port and starts a `Poco::Net::TCPServer` (or HTTP equivalent) with a connection-factory that produces handler instances.
10. **Background workers.** ZooKeeper session, DDL worker (consumes `ON CLUSTER` queue), part loader, distributed-insert directory queue scanners.

Shutdown reverses the process: stop accepting new connections, drain in-flight queries (up to `shutdown_wait_unfinished` seconds), stop background tasks, flush logs, release `Context`.

## Protocol handlers

Each protocol is one connection-per-thread (the threads are pooled). The handler's job is to translate the protocol's notion of "query" into a call into the universal `executeQuery` engine and stream results back in the protocol's format.

| Handler | File | Wire format |
| --- | --- | --- |
| `TCPHandler` | [src/Server/TCPHandler.cpp](../../src/Server/TCPHandler.cpp) | Native binary protocol. `Hello` → `Query` → multiple `Data` packets → `EndOfStream`. Used by `clickhouse-client`, drivers, and inter-server. |
| `HTTPHandler` | [src/Server/HTTPHandler.h](../../src/Server/HTTPHandler.h) | HTTP: `POST /?query=...` (body is the query or the data, depending), authentication via headers or URL params. |
| `MySQLHandler` | [src/Server/MySQLHandler.h](../../src/Server/MySQLHandler.h) | MySQL wire protocol — ClickHouse impersonates a MySQL server so BI tools / ORMs can connect. |
| `PostgreSQLHandler` | [src/Server/PostgreSQLHandler.h](../../src/Server/PostgreSQLHandler.h) | PostgreSQL wire protocol — same idea. |
| `GRPCServer` | [src/Server/GRPCServer.h](../../src/Server/GRPCServer.h) | gRPC service for languages without a native client. |
| `KeeperTCPHandler` | [src/Server/KeeperTCPHandler.h](../../src/Server/KeeperTCPHandler.h) | ZooKeeper-compatible wire protocol for the Keeper port. |
| `InterserverIOHTTPHandler` | [src/Server/InterserverIOHTTPHandler.h](../../src/Server/InterserverIOHTTPHandler.h) | HTTP server hosting the replication endpoints (see [07-distributed-and-coordination.md](07-distributed-and-coordination.md)). |
| `PrometheusRequestHandler` | [src/Server/PrometheusRequestHandler.h](../../src/Server/PrometheusRequestHandler.h) | Metrics scrape endpoint. |

### Anatomy of `TCPHandler::run`

A simplified trace of a typical `SELECT` over native TCP:

1. **Handshake.** Read `Hello` packet (client name/version, default DB, user, password). Authenticate via `IAccessControl`. Establish a `Session` ([src/Interpreters/Session.h](../../src/Interpreters/Session.h)) bound to this user.
2. **Per-query loop.** Each iteration:
   a. Read `Query` packet (query string, `Settings` overrides, `client_info`).
   b. Create a per-query `Context` via `Context::createCopy(session_context)`. Apply settings; install `process_list_entry`; set query ID, initial user, etc.
   c. Read any external tables (`Data` packets with name + `Native` block) into the query context.
   d. Call `executeQuery(query, query_context, ...)`, get back a `BlockIO`.
   e. For a `SELECT`: wrap the `BlockIO.pipeline` in `PullingPipelineExecutor`. Loop `pull(chunk)`, send each chunk as a `Data` packet (`Native`-format), interleave `Progress` and `Log` packets. End with `EndOfStream`.
   f. For an `INSERT`: send a `Data` packet describing the expected header. Read `Data` packets from the client. Push them through `PushingPipelineExecutor`.
3. **Exceptions.** Caught at the loop level, serialized into an `Exception` packet (with backtrace if `send_logs_level` allows), then the loop continues.
4. **Quotas / profile events.** Updated continuously; reported in `system.query_log` on completion.

`HTTPHandler` is structurally similar but stateless per request: parse the HTTP request, build a one-shot `Context`, run the query, stream the result body in the requested `FORMAT`.

## `Context`

[src/Interpreters/Context.h](../../src/Interpreters/Context.h) is, in a phrase, **the dependency-injection container of ClickHouse**. Every layer accesses settings, caches, the database catalog, access control, the thread pool, and current-query state through it.

Architecturally, `Context` is split:

- **`ContextSharedPart`** is process-wide and shared by every `Context` instance via `shared_ptr`. It owns:
  - The `Settings` registry definitions, the `FunctionFactory`/`AggregateFunctionFactory`/`TableFunctionFactory`/`FormatFactory`/`StorageFactory`/etc.
  - The `DatabaseCatalog`.
  - The access-control manager (`AccessControl`, `User`, `Role`, `Quota`, `RowPolicy`).
  - All the caches (mark, uncompressed, query result, ...).
  - All the thread pools.
  - All the system logs (`query_log`, `part_log`, `metric_log`, `trace_log`, ...).
  - The ZooKeeper / Keeper client.
  - DNS resolver, ZK queue, DDL worker, async-insert queue.
- A **`Context` instance** holds per-scope mutable state:
  - The current database name, current user, current query ID.
  - The current effective `Settings` (mutable copy; queries can `SET` them).
  - The `ContextAccess` (current user's effective grants).
  - Per-query scalars, prepared sets, temporary tables, external tables.
  - The `ProcessListEntry` (the row this query has in `system.processes`).
  - The current `QueryStatus`, used by `KILL QUERY`.

Contexts form a tree:

```
Global Context (singleton)
    ├── Session Context  (per TCP connection or per HTTP request)
    │       └── Query Context  (per query)
    │               ├── Subquery Context  (per scalar / IN subquery)
    │               └── Distributed Context  (per shard fragment)
```

Parents are reached by `getQueryContext()`, `getSessionContext()`, `getGlobalContext()`. The shared part is the same pointer everywhere; only the per-instance state changes.

`Context::createCopy(parent)` is used everywhere a fresh scope is needed. Distributed query fragments arrive at remote nodes carrying the originator's `Settings` and `client_info` — this is why a setting like `max_threads` set on the initiator transparently flows to all shards.

### Settings

[src/Core/Settings.h](../../src/Core/Settings.h) defines hundreds of knobs as a macro-expanded `Settings` struct. They're typed (`UInt64`, `Bool`, `String`, `Float`, `Milliseconds`, enums), and each carries a description and a `Tier` (`Production`, `Beta`, `Experimental`, `Obsolete`). The same machinery powers per-user defaults (in `users.xml`), per-profile defaults, per-query `SET`/`SETTINGS`, and the `system.settings` introspection table.

Notable subgroups: `max_*` (limits), `enable_*` / `allow_*` (feature gates), `optimize_*` (optimizer flags), `merge_tree_*` (read tuning), `background_*` (pool sizes), `input_format_*` / `output_format_*` (format tuning).

### Access control

`AccessControl` ([src/Access/AccessControl.h](../../src/Access/AccessControl.h)) is the singleton that holds users, roles, row policies, quotas, and settings profiles. The current `Context`'s `ContextAccess` is the **resolved** view for the current user: the union of their roles' grants, the applicable row policies, the active quota state.

Every access check goes through `ContextAccess::checkAccess(AccessType, db, table, ...)`. Row policies are inserted as extra `WHERE` clauses by the analyzer when reading a covered table.

## Concurrency control: CPU slots

Even with `max_threads = 16` per query, you don't want 100 concurrent queries × 16 threads = 1600 threads contending. The **concurrency control** layer ([src/Common/ConcurrencyControl.h](../../src/Common/ConcurrencyControl.h)) implements a fair-share allocator of CPU slots. `PipelineExecutor` requests slots when spawning workers; the allocator grants slots up to the global limit and demotes long-running queries so a flood of short queries can interleave.

This is what `max_concurrent_queries`, `max_threads`, `concurrent_threads_soft_limit_num` interact with.

## Putting the lifecycle together

```
clickhouse-server starts
    └─ Server.cpp::run()
         ├─ BaseDaemon: signals, logging
         ├─ load configs
         ├─ create global Context + SharedPart
         ├─ register factories (functions, formats, engines, ...)
         ├─ DatabaseCatalog: load metadata, attach databases
         ├─ thread pools, caches
         └─ start listeners (TCP/HTTP/...)

TCP connection accepted
    └─ new thread, new TCPHandler
         ├─ Hello → authenticate → Session
         └─ loop:
              ├─ Query → query Context = createCopy(session_context)
              ├─ executeQuery() → BlockIO {pipeline, ...}
              ├─ PullingPipelineExecutor.pull → Data packets
              └─ EndOfStream
```

## Things to know when you hack on this layer

- **Avoid stashing query-scoped state in the shared part.** Use the per-query `Context` (or a member of it). Mistakes here leak across queries.
- **Almost every method takes a `ContextPtr` or `ContextMutablePtr`.** Don't introduce side-channels (statics, TLS) when you could thread the context.
- **Settings changes can't break a running pipeline.** Pipelines snapshot the values they need at construction time. If you add a new setting, decide whether it's read at planning time, execution time, or both.
- **Adding a new protocol handler** is mostly: create a `IServer`-style class, wire it in `Server.cpp` to a port, and translate its protocol's "send a query" to `executeQuery` and back. The MySQL/PostgreSQL handlers are good templates.
