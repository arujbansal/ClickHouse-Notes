# Processors and the Pipeline Executor

This is the heart of execution. Everything between "the planner has decided what to do" and "the network handler is writing bytes" runs as a graph of `IProcessor`s scheduled by `PipelineExecutor`. Understanding this model is the prerequisite for adding any kind of transform, source, or sink.

## Why processors and not iterators

Early ClickHouse used **block streams** — a tree of `IBlockInputStream`s, each pulling from its child via `read()` and returning a `Block`. That model is easy to understand (it's just nested calls) but has three structural problems:

1. **Single-threaded by construction.** Parallelism is shoehorned in by special-case stream types.
2. **No first-class async I/O.** A stream stuck on a network read blocks its thread; you can't yield.
3. **Hard to express graphs.** Any fan-in/fan-out (resize, merge of N sorted inputs) is awkward.

The processor model fixes all three. The cost is a more elaborate state machine; the payoff is that **every transform you write automatically benefits from multi-threading, async I/O, and dynamic pipeline reshaping**.

## `IProcessor`: the state machine

[src/Processors/IProcessor.h](../src/Processors/IProcessor.h) defines `IProcessor`. The contract is unusual: a processor never produces or consumes data on its own — it tells the scheduler what it needs and what it can do, and the scheduler routes data through ports.

### Status enum

The core enum (`IProcessor::Status`):

| Status | Meaning |
| --- | --- |
| `NeedData` | "I'm waiting for input on at least one of my input ports." |
| `PortFull` | "I have output ready but my downstream's input port is full." |
| `Ready` | "I can do compute now. Call my `work()`." |
| `Async` | "I'm doing I/O; call `schedule()` to get an fd, then `work()` when ready." |
| `Finished` | "Done. Won't produce anything more." |
| `ExpandPipeline` | "Run my `expandPipeline()` to splice new processors into the graph." |

### The `prepare()` / `work()` split

The single most important design point in this layer:

- **`prepare()`** is **cheap, single-threaded per processor, no I/O, no compute**. It inspects port states (data available? downstream needs more?), shuffles a `Chunk` from input ports into internal storage or from internal storage to output ports, and returns a `Status`.
- **`work()`** is **the actual compute** (apply an expression, hash a batch, sort-merge). It only touches data that `prepare()` staged. It can run on **any** thread and in parallel with other processors' `work()`s.
- **`schedule()`** is called when `prepare()` returns `Async`; it gives the executor a file descriptor (e.g. for S3 readiness) to poll on.

Because `prepare()` is the only thing that touches ports, and the executor calls each processor's `prepare()` under a per-node mutex, **port traffic is lock-free for the caller** — the synchronization happens in the scheduler. `work()` only sees thread-local staged data, so it doesn't need locks either.

### Why this is a big deal

A processor's `work()` is just a function over a `Chunk`. The compiler can inline freely, SIMD-vectorize loops, and never worries about contention. The complicated graph-management code is concentrated in one place (the executor) instead of being spread across every transform implementation.

## Ports

[src/Processors/Port.h](../src/Processors/Port.h) defines `InputPort` and `OutputPort`. A port has:

- A **header** (`Block` with `nullptr` columns) describing the schema flowing through it.
- A **state**: roughly `IS_FINISHED`, `IS_NEEDED` (the downstream is hungry), `HAS_DATA` (a chunk is staged).
- A **single peer** (one output connects to exactly one input — fan-out happens through a `Resize` or copy processor, not duplicated ports).

The handshake is done with atomic CAS, with status flags packed into the low bits of a pointer. `push(chunk)` on an output port flips `HAS_DATA`; `pull()` on the connected input clears it. An `UpdatedPortsList` on each node tells the executor *which* neighbors should be re-prepared when a port transitions — that's what makes scheduling incremental rather than rerunning every processor's `prepare()` after every chunk.

## Concrete processor families

Most transforms inherit from one of these helpers in [src/Processors/](../src/Processors/) rather than `IProcessor` directly.

| Family | Shape | When to use it |
| --- | --- | --- |
| `ISource` ([ISource.h](../src/Processors/ISource.h)) | 0→1 | Generate chunks (read from storage, evaluate a constant table function, ...) |
| `ISink` ([ISink.h](../src/Processors/ISink.h)) | 1→0 | Consume chunks (an output format, a final inserter) |
| `ISimpleTransform` ([ISimpleTransform.h](../src/Processors/ISimpleTransform.h)) | 1→1 | Stateless per-chunk transform (`ExpressionTransform`, `FilterTransform`) |
| `IAccumulatingTransform` ([IAccumulatingTransform.h](../src/Processors/IAccumulatingTransform.h)) | 1→1 | Must see *all* input before producing output (`SortingTransform`, naive aggregation) |
| `IMergingTransform<Algorithm>` ([Merges/IMergingTransform.h](../src/Processors/Merges/IMergingTransform.h)) | N→1 | Merge N sorted/keyed streams (e.g. `MergingSortedTransform`, `AggregatingSortedTransform`) |
| `ResizeProcessor` ([ResizeProcessor.h](../src/Processors/ResizeProcessor.h)) | N→M | Redistribute data across streams (used everywhere parallelism width changes) |

Concrete examples worth knowing:

- **`ExpressionTransform`** ([src/Processors/Transforms/ExpressionTransform.h](../src/Processors/Transforms/ExpressionTransform.h)) — runs a compiled `ActionsDAG` over each input chunk. This is how `SELECT` expressions and post-WHERE projections are computed.
- **`FilterTransform`** ([src/Processors/Transforms/FilterTransform.h](../src/Processors/Transforms/FilterTransform.h)) — evaluates a boolean column and applies `IColumn::filter` to drop rows.
- **`AggregatingTransform`** ([src/Processors/Transforms/AggregatingTransform.h](../src/Processors/Transforms/AggregatingTransform.h)) — feeds chunks to an `Aggregator` that maintains a hash table of states. Many of these run in parallel (one per source stream), followed by a `MergingAggregatedTransform` that combines their partial results.
- **`MergingSortedTransform`** ([src/Processors/Merges/MergingSortedTransform.h](../src/Processors/Merges/MergingSortedTransform.h)) — N→1 K-way merge of sorted streams (used at the top of `ORDER BY` after parallel partial sorts).

## `QueryPipeline` and `QueryPipelineBuilder`

[src/QueryPipeline/QueryPipelineBuilder.h](../src/QueryPipeline/QueryPipelineBuilder.h) is what plan-step lowering uses. It tracks a vector of output ports that represent the current "wavefront" of the pipeline as you append steps. Useful methods:

- `addSimpleTransform(getter)` — install a 1→1 transform on every current stream.
- `addTransform(processor)` — install one N-input processor that consumes all current streams.
- `resize(num_streams)` — insert a `ResizeProcessor` to widen or narrow parallelism.
- `transform(lambda)` — most general form: take the current streams, return new ones.

When the builder is done, `getPipeline()` returns a finalized `QueryPipeline` ([src/QueryPipeline/QueryPipeline.h](../src/QueryPipeline/QueryPipeline.h)) which falls into one of three shapes:

| Shape | External port(s) | Used for |
| --- | --- | --- |
| `pulling()` | one output | `SELECT`: the caller pulls chunks |
| `pushing()` | one input | `INSERT ... VALUES`: the caller pushes parsed rows |
| `completed()` | none | DDL-like queries that have no result and no client input |

## `PipelineExecutor`: scheduling

[src/Processors/Executors/PipelineExecutor.h](../src/Processors/Executors/PipelineExecutor.h) is the runtime that actually runs the pipeline. It wraps the pipeline's processors in an [`ExecutingGraph`](../src/Processors/Executors/ExecutingGraph.h) — one `Node` per processor with execution status (`Idle`/`Preparing`/`Executing`/`Async`/`Finished`), backward edges for coordination, and a per-node mutex.

The loop, in spirit:

1. Initialize: spawn N worker threads (capped by `max_threads` and the CPU-slot allocator that fair-shares cores between concurrent queries).
2. Each worker pulls a node from the task queue.
3. Take the node's mutex; call its processor's `prepare()`.
4. Based on the returned status:
   - `Ready` → release the mutex, call `work()` (no mutex held; parallel-safe), then mark neighbors to be re-prepared.
   - `Async` → call `schedule()`, register the returned fd with epoll, park the node. When epoll fires, requeue.
   - `NeedData` / `PortFull` → the updated ports list tells the executor which neighbor nodes to re-prepare.
   - `Finished` → mark done; propagate finish to neighbors.
   - `ExpandPipeline` → call `expandPipeline()` (still under the mutex) to splice new processors in.
5. Stop when the graph reaches a quiescent state with all output ports finished.

The result is that prepares are serialized *per processor* (lock-free port reads/writes are safe), but `work()` runs in parallel across the whole graph, async I/O doesn't pin threads, and the graph itself can grow during execution (subqueries materialize as new subgraphs).

## Entry points: pulling / pushing executors

You rarely instantiate `PipelineExecutor` directly. Three thin façades cover all uses:

- **`PullingPipelineExecutor`** ([src/Processors/Executors/PullingPipelineExecutor.h](../src/Processors/Executors/PullingPipelineExecutor.h)) — for `SELECT`. The caller's thread calls `pull(chunk)` in a loop; internally the executor runs worker threads and serves chunks through a `LazyOutputFormat` sink.
- **`PushingPipelineExecutor`** ([src/Processors/Executors/PushingPipelineExecutor.h](../src/Processors/Executors/PushingPipelineExecutor.h)) — for `INSERT`. The caller calls `start()`, then `push(chunk)` repeatedly, then `finish()`.
- **`CompletedPipelineExecutor`** ([src/Processors/Executors/CompletedPipelineExecutor.h](../src/Processors/Executors/CompletedPipelineExecutor.h)) — runs a `completed()` pipeline to its end with no external port interaction.

These are what `TCPHandler` / `HTTPHandler` / `executeQuery` actually drive.

## Writing your own processor

Five-rule cheat sheet:

1. **Choose the right base class.** If your operation is stateless per chunk → `ISimpleTransform`. If you must see everything → `IAccumulatingTransform`. If it's N→1 over sorted inputs → `IMergingTransform`. Only inherit `IProcessor` directly for true graph oddities.
2. **`prepare()` must be cheap and not block.** No I/O, no allocations beyond port bookkeeping, no syscalls. Anything heavy → `work()`.
3. **Don't share mutable state between `work()` calls of different processors.** Different processors can run their `work()` simultaneously.
4. **Move chunks, don't copy them.** `Chunk` is move-only for a reason; sticking a `std::move` in `prepare()` is normal.
5. **For async I/O, return `Async` and implement `schedule()`.** Don't sleep, don't poll inside `work()` — yield to the executor.

## Useful diagnostics

- `EXPLAIN PIPELINE graph=1` → Graphviz of the actual processor graph.
- `system.processors_profile_log` → per-processor elapsed time and chunk counts for completed queries (enable `log_processors_profiles = 1`).
- `system.processes` → live queries; the `peak_threads_usage` column tells you the max width achieved.
