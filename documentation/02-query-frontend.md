# Query Frontend: SQL → Pipeline

This file covers everything between the network handler receiving a query string and the `PipelineExecutor` starting to execute. There are five distinct stages: **parse → analyze → plan → optimize → lower**. Each stage produces a different IR.

```
SQL text
  ──parser──►  IAST            (syntactic; identifiers are strings)
  ──analyzer──►  QueryTree     (semantic; identifiers resolved, types known)
  ──planner──►   QueryPlan     (logical operators; can still be rewritten)
  ──optimizer──► QueryPlan     (same shape, smarter)
  ──lower──►     QueryPipeline (physical: a graph of IProcessor)
```

`executeQuery` in [src/Interpreters/executeQuery.cpp](../src/Interpreters/executeQuery.cpp) drives all of this.

## 1. Parser

ClickHouse uses **hand-written recursive-descent parsers**, not a generated one. The reason is good error messages on a large dialect with many context-sensitive bits (e.g. `WITH` queries, lambdas, complex `JOIN` syntax).

Key files in [src/Parsers/](../src/Parsers/):

- [src/Parsers/IParser.h](../src/Parsers/IParser.h) — base class. Each parser exposes `parseImpl(Pos & pos, ASTPtr & node, Expected & expected)`. `Pos` tracks the current token, depth, and backtrack state. `Expected` accumulates "what we hoped to see," used to render the `Expected ... near '...'` errors.
- [src/Parsers/ParserQuery.h](../src/Parsers/ParserQuery.h) — top-level dispatch. Tries `ParserSelectWithUnionQuery`, `ParserInsertQuery`, `ParserCreateQuery`, etc., in turn.
- [src/Parsers/parseQuery.h](../src/Parsers/parseQuery.h) — the `parseQuery` free function: tokenize, run the parser, produce an `ASTPtr`.
- [src/Parsers/IAST.h](../src/Parsers/IAST.h) — `IAST` is the AST node base. Important node families: `ASTSelectQuery`, `ASTSelectWithUnionQuery`, `ASTFunction`, `ASTIdentifier`, `ASTLiteral`, `ASTTableExpression`, `ASTOrderByElement`, `ASTAlterCommand`, ...

An AST is **purely syntactic**. `ASTIdentifier("x")` doesn't know whether `x` is a column, an alias, or a table; that's the analyzer's job.

There is also a dialect dispatch layer: under settings, you can parse Kusto (KQL), PRQL, or Prometheus. They all produce a normal `IAST` so the rest of the pipeline doesn't care.

## 2. Analyzer (the new path)

For a long time ClickHouse used `ExpressionAnalyzer` ([src/Interpreters/ExpressionAnalyzer.h](../src/Interpreters/ExpressionAnalyzer.h)) which rewrote the AST in place to perform semantic analysis. That was hard to extend (rewriting AST while it's being interpreted) and the project replaced it with the **Analyzer** in [src/Analyzer/](../src/Analyzer/). The old path still exists for `INSERT`, DDL, and as a compatibility fallback (controlled by the `allow_experimental_analyzer` setting, which now defaults on), but **all SELECT queries on modern ClickHouse go through the new analyzer**.

The new analyzer introduces a different IR — the `QueryTree`:

- [src/Analyzer/IQueryTreeNode.h](../src/Analyzer/IQueryTreeNode.h) — base class. Node types include `QUERY`, `UNION`, `IDENTIFIER`, `COLUMN`, `FUNCTION`, `CONSTANT`, `LAMBDA`, `TABLE`, `JOIN`, `ARRAY_JOIN`, `MATCHER` (`SELECT *`), `WINDOW`, `SORT`.
- [src/Analyzer/QueryTreeBuilder.h](../src/Analyzer/QueryTreeBuilder.h) — `buildQueryTree(ASTPtr, ContextPtr)`: translates a parsed AST into a `QueryTreeNodePtr`.

Then it runs a pass pipeline ([src/Analyzer/Passes/](../src/Analyzer/Passes/)). The central one is **`QueryAnalysisPass`** ([src/Analyzer/Passes/QueryAnalysisPass.h](../src/Analyzer/Passes/QueryAnalysisPass.h)), which does the heavy lifting of name resolution, type inference, aggregation/window validation, scalar subquery handling, and constant folding. After it runs, every identifier resolves to a concrete `ColumnNode`/`TableNode`/`FunctionNode`, every `FunctionNode` has a resolved `IFunctionBase`, and every node has a known `DataTypePtr`.

Other passes (~30 total) perform targeted rewrites: `CrossToInnerJoinPass`, `IfChainToMultiIfPass`, `LogicalExpressionOptimizerPass`, `OrderByLimitByDuplicateEliminationPass`, `FuseFunctionsPass` (e.g. `sum(x) / count(x)` → `avg(x)`), and so on. They run in a fixed order via `QueryTreePassManager`.

**Why a separate tree, not AST rewriting?** ASTs are designed to round-trip back to text (for `EXPLAIN AST`, server logs, distributed query shipping). The QueryTree carries semantic info that doesn't survive the round trip (resolved overloads, types, alias graphs). Keeping them separate means analyzer passes can freely mutate the QueryTree without breaking AST printing.

## 3. Planner

[src/Planner/Planner.h](../src/Planner/Planner.h) consumes an analyzed `QueryTreeNodePtr` and emits a `QueryPlan`.

Construction takes the QueryTree, a `SelectQueryOptions`, and a `PlannerContext` (carries the global `Context` plus per-query state like the table-expression-to-storage map). Important methods:

- `buildQueryPlanIfNeeded()` — lazy entry point.
- `buildPlanForQueryNode()` / `buildPlanForUnionNode()` — recursive builders.

The Planner is where set-oriented decisions get made: which JOIN algorithm (`hash` / `parallel_hash` / `partial_merge` / `direct` / ...), whether to perform partial aggregation locally before shuffling, how to handle `IN (SELECT ...)` (broadcast vs build sets), where to place sort barriers. It is *not* yet physical execution — it builds a tree of plan steps.

## 4. QueryPlan and its optimizations

[src/Processors/QueryPlan/QueryPlan.h](../src/Processors/QueryPlan/QueryPlan.h) defines `QueryPlan`, a tree of `QueryPlan::Node`s each owning an `IQueryPlanStep` ([src/Processors/QueryPlan/IQueryPlanStep.h](../src/Processors/QueryPlan/IQueryPlanStep.h)).

A small but representative set of steps (all in `src/Processors/QueryPlan/`):

| Step | Role |
| --- | --- |
| `ReadFromMergeTree` | Read parts/granules from a MergeTree table (most important leaf). |
| `ReadFromRemote` | Issue a subquery to a remote shard. |
| `FilterStep` | `WHERE` / `HAVING`. |
| `ExpressionStep` | Compute SELECT-list / expressions (wraps `ActionsDAG`). |
| `AggregatingStep` / `MergingAggregatedStep` | Partial and final `GROUP BY`. |
| `SortingStep` | `ORDER BY`. |
| `LimitStep`, `OffsetStep`, `DistinctStep` | What they say on the tin. |
| `JoinStep`, `ArrayJoinStep` | Joins / `ARRAY JOIN`. |
| `UnionStep` | Combine plans for `UNION`. |
| `CreatingSetsStep` | Materialize `IN (subquery)`. |

The plan is then optimized in three passes; the entry points and full pass list live in [src/Processors/QueryPlan/Optimizations/Optimizations.h](../src/Processors/QueryPlan/Optimizations/Optimizations.h):

1. **First-pass optimizations** (local, idempotent): `liftUpArrayJoin`, `pushDownLimit`, `splitFilter`, `mergeExpressions`, `filterPushDown`, `convertOuterJoinToInnerJoin`, `convertLogicalJoinStepsToPhysical`, ...
2. **Second-pass optimizations** (storage-aware): `optimizePrimaryKeyConditionAndLimit` (pushes WHERE bounds into MergeTree's mark-range computation), `optimizePrewhere` (moves cheap, selective predicates into PREWHERE so they read fewer columns), `optimizeReadInOrder` (lets MergeTree return rows pre-sorted so `ORDER BY` becomes free), `optimizeAggregationInOrder` (same for `GROUP BY`).
3. **Third pass**: `addStepsToBuildSets` materializes any `IN (subquery)` once.

These optimizations are why query performance is often dominated by *which* of these passes fired — `EXPLAIN PIPELINE` and `EXPLAIN indexes = 1` are the standard tools.

## 5. Lowering: QueryPlan → QueryPipeline

Each `IQueryPlanStep` knows how to build its physical implementation via `updatePipeline(QueryPipelineBuilders, BuildQueryPipelineSettings)`. The Interpreter walks the plan top-down, threading a `QueryPipelineBuilder` ([src/QueryPipeline/QueryPipelineBuilder.h](../src/QueryPipeline/QueryPipelineBuilder.h)) through it, and the result is a `QueryPipeline` ([src/QueryPipeline/QueryPipeline.h](../src/QueryPipeline/QueryPipeline.h)) — the actual graph of `IProcessor`s that will execute. See [03-processors-and-pipeline.md](03-processors-and-pipeline.md).

## 6. Interpreters

The top-level dispatcher is [src/Interpreters/InterpreterFactory.h](../src/Interpreters/InterpreterFactory.h). It maps AST node types to interpreter classes:

| Query type | Interpreter |
| --- | --- |
| `SELECT` (new path) | `InterpreterSelectQueryAnalyzer` ([src/Interpreters/InterpreterSelectQueryAnalyzer.h](../src/Interpreters/InterpreterSelectQueryAnalyzer.h)) |
| `SELECT` (legacy) | `InterpreterSelectQuery` ([src/Interpreters/InterpreterSelectQuery.h](../src/Interpreters/InterpreterSelectQuery.h)) |
| `INSERT` | `InterpreterInsertQuery` |
| `CREATE TABLE/VIEW/DATABASE` | `InterpreterCreateQuery` |
| `ALTER` | `InterpreterAlterQuery` |
| `OPTIMIZE`, `SYSTEM`, `KILL`, ... | dedicated interpreters |

Every interpreter implements `IInterpreter::execute()` returning a `BlockIO` — a small bundle holding the resulting `QueryPipeline` (in/out, depending on direction) and lifetime objects. For `SELECT`, the returned pipeline is *pulling* (the caller pulls chunks); for `INSERT ... VALUES`, it's *pushing* (the caller pushes parsed rows); for some DDLs, it's *completed* (no I/O, the executor runs it to completion internally).

The entry point that ties parser, interpreter, and pipeline together is `executeQuery`/`executeQueryImpl` in [src/Interpreters/executeQuery.cpp](../src/Interpreters/executeQuery.cpp). That file is also where logging, query-log writing, exception conversion, on-error callbacks, and the various pre/post hooks live — when you debug "why did this query do X," it's usually the right first stop.

## 7. Context

[src/Interpreters/Context.h](../src/Interpreters/Context.h) is the omnipresent object that ties all of the above together. There is a single `ContextSharedPart` (process-wide; databases, settings registry, function/aggregate function factories, caches, thread pools, the metric system) and an arbitrary number of `Context` instances (per-query, per-subquery, per-distributed-fragment) that share the `SharedPart` by pointer and own their own mutable per-query state.

What a `Context` carries that you care about:

- **Settings.** `context->getSettingsRef()` → `Settings` ([src/Core/Settings.h](../src/Core/Settings.h)). All knobs (`max_threads`, `max_memory_usage`, `allow_experimental_analyzer`, hundreds more).
- **Database catalog.** `context->getCurrentDatabase()`, table lookups via `DatabaseCatalog`. See [04-storages-and-mergetree.md](04-storages-and-mergetree.md).
- **Access control.** `ContextAccess`, row policies, quotas, user role.
- **Caches.** Mark cache, uncompressed cache, query result cache, query condition cache.
- **Per-query state.** Current user/initial user, query ID, scalars (results of scalar subqueries), prepared sets (for `IN`), temporary tables, external tables shipped from the client.
- **Process list entry.** The `system.processes` row; used by `KILL QUERY`.

Construction is `Context::createGlobal(shared_part)` for the bootstrap singleton and `Context::createCopy(parent)` for everything else. Distributed query fragments arrive at remote nodes carrying the *settings* and *user* from the originator — that's why a `Settings` change on the initiator transparently propagates to all shards.

## Putting it together

```
                                          ┌──────────────────────┐
SQL text ─► parseQuery ─► ASTPtr ─────────► InterpreterFactory   │
                                          └──────────┬───────────┘
                                                     │  (SELECT?)
                                                     ▼
                              InterpreterSelectQueryAnalyzer
                                                     │
                                  QueryTreeBuilder   │
                                                     ▼
                                          QueryTreeNodePtr
                                                     │
                                  QueryTreePassManager (~30 passes)
                                                     │
                                                     ▼
                                            (analyzed QueryTree)
                                                     │
                                                     ▼
                                                Planner
                                                     │
                                                     ▼
                                              QueryPlan
                                                     │
                                       QueryPlan optimizations (3 passes)
                                                     │
                                                     ▼
                                  IQueryPlanStep::updatePipeline ...
                                                     │
                                                     ▼
                                             QueryPipeline
                                                     │
                                                     ▼
                                          (handed off to executor)
```

## Reading these files for the first time

Useful exercise: run a query through every stage manually. The IRs are dumpable.

```sql
EXPLAIN AST          SELECT count() FROM hits WHERE url LIKE '%example%';
EXPLAIN QUERY TREE   SELECT count() FROM hits WHERE url LIKE '%example%';
EXPLAIN PLAN         SELECT count() FROM hits WHERE url LIKE '%example%';
EXPLAIN PLAN actions=1, indexes=1
                     SELECT count() FROM hits WHERE url LIKE '%example%';
EXPLAIN PIPELINE     SELECT count() FROM hits WHERE url LIKE '%example%';
EXPLAIN PIPELINE graph=1, compact=0
                     SELECT count() FROM hits WHERE url LIKE '%example%';
```

The last one prints a Graphviz of the actual processor graph; pipe it into `dot -Tpng` and you have a picture of what `PipelineExecutor` will run.
