# Functions, Aggregates, and Expression Evaluation

This file covers the three function families (ordinary, aggregate, table), the `ActionsDAG` expression layer that wires them into the pipeline, and the JIT compiler.

## Ordinary functions

[src/Functions/IFunction.h](../src/Functions/IFunction.h) defines the function interface in three layers:

- **`IFunctionOverloadResolver`** — chooses an overload given argument *types*. This is what `FunctionFactory::get(name, args, context)` returns. It exists because most functions have many type signatures (`plus(Int32, Int32)` vs `plus(Decimal, Decimal)` vs `plus(Date, Int32)` ...), and resolving overloads is a separate concern from executing them.
- **`IFunctionBase`** — a function *bound to specific argument types*. Knows its return type, whether it's deterministic / monotonic / suitable for index analysis, and how to produce an `IExecutableFunction`. Also where `isCompilable()`/`compile()` live for JIT.
- **`IExecutableFunction`** — actually does the work. Its single important method is `executeImpl(const ColumnsWithTypeAndName & args, const DataTypePtr & result_type, size_t input_rows_count)` which **operates on full columns** and returns a result column. That's the vectorization.

Functions are registered through a singleton factory ([src/Functions/FunctionFactory.h](../src/Functions/FunctionFactory.h)) via `REGISTER_FUNCTION(Name)` blocks. A typical `.cpp` (e.g. [src/Functions/plus.cpp](../src/Functions/plus.cpp)) defines a tiny per-element `apply` and instantiates a `BinaryArithmeticOverloadResolver<PlusImpl>` template that handles type matrices automatically.

**The vectorization assumption matters.** A function's `executeImpl` is called *once* per chunk for *all* rows. Per-row dispatch (a virtual call per value) would erase ClickHouse's perf advantage; instead a function generally looks like:

```cpp
// inside a numeric function
const auto & a_data = a_col->getData();   // PaddedPODArray<T>
const auto & b_data = b_col->getData();
auto & out_data    = out_col->getData();
out_data.resize(input_rows_count);
for (size_t i = 0; i < input_rows_count; ++i)
    out_data[i] = Op::apply(a_data[i], b_data[i]);
```

That inner loop is straight-line, branchless, and the compiler vectorizes it.

Don't forget the wrapper columns. `ColumnConst`, `ColumnNullable`, `ColumnLowCardinality`, `ColumnSparse` either need special handling or `materialize`/`convertToFull*` calls. Most functions delegate via helpers like `castColumn` or use `FunctionHelpers` to standardize.

## `ActionsDAG`: the expression IR

[src/Interpreters/ActionsDAG.h](../src/Interpreters/ActionsDAG.h) is the compiled representation of an expression. It's a DAG (not a tree — common subexpressions are deduplicated) of typed `Node`s:

| Node type | What it does |
| --- | --- |
| `INPUT` | A column read from the source chunk. |
| `COLUMN` | A literal/constant column. |
| `ALIAS` | Renames a node. |
| `FUNCTION` | Apply an `IExecutableFunction` to inputs. |
| `ARRAY_JOIN` | The `ARRAY JOIN` operator. |

`ActionsDAG` is what the analyzer produces from `SELECT` expressions, `WHERE`, `JOIN ON`, etc. It's then "compiled" into an `ExpressionActions` which `ExpressionTransform` evaluates over each chunk.

Key operations:

- `clone`, `merge`, `splitActionsBeforeArrayJoin`, `splitActionsForFilter` — used by optimizer passes (filter pushdown, PREWHERE extraction).
- `compileExpressions` — if JIT is enabled, fuses a subgraph of compilable function nodes into a single LLVM-generated function.

## Aggregate functions

[src/AggregateFunctions/IAggregateFunction.h](../src/AggregateFunctions/IAggregateFunction.h) defines `IAggregateFunction`. Unlike ordinary functions, aggregates carry **mutable state per group**. The lifecycle:

1. **Allocate state.** `create(place)` placement-news a state struct (e.g. `{UInt64 sum; UInt64 count;}` for `avg`) into memory owned by an `Arena`.
2. **Accumulate.** `add(place, columns, row, arena)` for one row, `addBatch(...)` for many, `addBatchSinglePlace(...)` when all rows go to one group (e.g. global aggregation, no GROUP BY).
3. **Merge.** `merge(place_a, place_b, arena)` combines two states. Used both for two-level aggregation (parallel partial → final) and distributed (remote → initiator).
4. **Serialize / deserialize.** For shipping intermediate states between nodes (distributed) or persisting them (`AggregatingMergeTree`, `-State` combinator).
5. **Finalize.** `insertResultInto(place, result_col)` materializes the final value (e.g. `sum / count` for `avg`).

`Arena` allocation is important: aggregate states are tiny but plentiful (one per group). A bump allocator avoids `malloc` overhead.

`AggregateFunctionFactory` ([src/AggregateFunctions/AggregateFunctionFactory.h](../src/AggregateFunctions/AggregateFunctionFactory.h)) registers them. The factory also recognizes **combinator suffixes**:

| Combinator | Effect |
| --- | --- |
| `-If` | Conditional aggregation: extra boolean argument. `sumIf(x, cond)`. |
| `-Array` | Apply per element of an array argument. `sumArray(arr)`. |
| `-Map` | Apply per Map value. |
| `-State` | Return the intermediate state instead of the final result (binary-serialized). |
| `-Merge` | Take serialized states and merge them. `sumMerge(states)`. |
| `-MergeState` | `-Merge` then return state. |
| `-ForEach` | Apply across arrays element-wise, returning an array of results. |
| `-Distinct` | Apply only to distinct values. |
| `-OrNull`, `-OrDefault`, `-Resample` | Result-shape combinators. |

Combinators stack: `quantileIfMerge` is `quantile` + `-If` + `-Merge`. Combinator detection works by repeated suffix stripping in the factory. This is what makes ClickHouse's `MaterializedView` + `AggregatingMergeTree` + `-State`/`-Merge` pattern compose so cleanly.

## How aggregation runs at execution time

The `AggregatingStep` lowers into `AggregatingTransform` ([src/Processors/Transforms/AggregatingTransform.h](../src/Processors/Transforms/AggregatingTransform.h)) plus possibly `MergingAggregatedTransform`. Internals:

- The **`Aggregator`** ([src/Interpreters/Aggregator.h](../src/Interpreters/Aggregator.h)) is the workhorse. It chooses a hash-table variant based on key types and cardinality (small `UInt8` keys → array-indexed, single string → `HashMap<StringRef>`, multi-column → packed keys, ...). The dispatch is template-generated; there are dozens of variants and the choice matters a lot for performance.
- **Two-level aggregation.** When the hash table gets large, the aggregator splits it into 256 buckets by hash, and emits each bucket separately so downstream merges can run in parallel.
- **Partial / final split.** With `GROUP BY` on a clustered key, the aggregator can be split into multiple parallel `AggregatingTransform`s (one per source stream), each producing partial results, followed by `MergingAggregatedTransform` to combine them. This is also how distributed aggregation works: remote shards return states, the initiator merges.

## Table functions

[src/TableFunctions/ITableFunction.h](../src/TableFunctions/ITableFunction.h). Unlike ordinary or aggregate functions, table functions are *not* called during execution — they're called at *planning* time and produce a `StoragePtr` that then participates as a `FROM`-clause source.

Examples: `numbers(N)`, `remote(...)` / `cluster(...)`, `s3(...)`, `url(...)`, `file(...)`, `view(query)`, `merge('db', 'regex')`.

They're useful for ad-hoc/external data sources (`s3('s3://bucket/*.parquet')` is a one-liner ad-hoc table) and for parametrized references to clusters/remotes.

## JIT compilation

ClickHouse can JIT-compile both expressions and aggregate function pipelines using LLVM. Enabled at build time via `USE_EMBEDDED_COMPILER` and at runtime via the `compile_expressions` / `min_count_to_compile_expression` / `compile_aggregate_expressions` settings.

- [src/Interpreters/JIT/CHJIT.h](../src/Interpreters/JIT/CHJIT.h) — wraps LLVM's ORC JIT. Compiled modules are cached by hash of the source IR, so the second query that uses the same expression skips compilation.
- A subgraph of `ActionsDAG` nodes is JIT-compilable if every function in it implements `isCompilable()` and `compile(IRBuilder, args)`. The compiler fuses them into one LLVM function that takes column pointers and writes to an output column — eliminating the per-function virtual call and intermediate columns.
- Aggregate functions can also expose JIT versions of `add` / `merge` / `insertResult`. With `compile_aggregate_expressions = 1`, the aggregator's inner loop (read keys → lookup hash table → run `add` for each aggregate) is generated as a single LLVM function.

JIT pays off most for expression-heavy queries with several arithmetic/comparison ops per row, where the function call overhead and intermediate column allocations dominate. It's not a magic bullet — vectorized non-JIT execution is already very fast — but for narrow CPU-bound queries it can give 1.5–3× speedups.

## Where to put what

Quick mapping for "I want to add X":

- **A new scalar function.** New `.cpp` in `src/Functions/`. Inherit from an existing template family (`FunctionStringToString`, `BinaryArithmeticOverloadResolver`, ...) when possible; otherwise implement `IFunction`/`IExecutableFunction`. `REGISTER_FUNCTION(...)` at the bottom.
- **A new aggregate function.** New `.cpp` in `src/AggregateFunctions/`. Implement `IAggregateFunctionDataHelper<Data, Self>` (provides `create`/`destroy`/etc. given a `Data` POD). `registerAggregateFunctionX()` from `registerAggregateFunctions.cpp`.
- **A new combinator.** `src/AggregateFunctions/Combinators/`. Implement `IAggregateFunctionCombinator`; register in the combinator factory.
- **A new table function.** `src/TableFunctions/`. Implement `ITableFunction`; register in `registerTableFunctions.cpp`.
- **JIT support for an existing function.** Add `isCompilable()` returning true and a `compile(IRBuilder&, args)` that emits the IR. Test that compiled and non-compiled results match — that's the easiest place to introduce subtle bugs.
