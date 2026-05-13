# Core Data Model

Five abstractions show up in nearly every file in `src/`. Understand these before reading anything else.

| Concept | What it represents | Key file |
| --- | --- | --- |
| `IColumn` | A contiguous chunk of one column's values | [src/Columns/IColumn.h](../src/Columns/IColumn.h) |
| `IDataType` | The *type* of a column (UInt32, Nullable(String), Array(Int64), ...) | [src/DataTypes/IDataType.h](../src/DataTypes/IDataType.h) |
| `Field` | A single value (any type) — the slow path | [src/Core/Field.h](../src/Core/Field.h) |
| `Block` | A bag of `{ColumnPtr, DataTypePtr, name}` triples | [src/Core/Block.h](../src/Core/Block.h) |
| `Chunk` | A leaner `Block` used inside processors | [src/Processors/Chunk.h](../src/Processors/Chunk.h) |

## `IColumn` — columnar storage

[src/Columns/IColumn.h](../src/Columns/IColumn.h) defines the interface. Important traits:

- Inherits from `COW<IColumn>` ([src/Common/COW.h](../src/Common/COW.h)). Two pointer types matter: `ColumnPtr` (= `immutable_ptr<IColumn>`, shareable) and `MutableColumnPtr` (= `mutable_ptr<IColumn>`, unique). To modify a shared column you call `IColumn::mutate(ptr)`; it clones if the use count is > 1 and reuses in-place otherwise. **This is why columns can be passed between processors without locks.**
- Values are not accessed one-at-a-time in hot paths. Use the bulk methods — `insertRangeFrom`, `filter`, `permute`, `replicate`, `compareAt`, `updateHashWithValue` — which the compiler can vectorize.

### Concrete families

All of these are in `src/Columns/`:

| Implementation | Purpose |
| --- | --- |
| `ColumnVector<T>` | Fixed-width numeric (Int*/UInt*/Float*/Date/DateTime). A `PaddedPODArray<T>` plus a small header. |
| `ColumnString`, `ColumnFixedString` | Variable- and fixed-length strings; `ColumnString` is `chars` + `offsets`. |
| `ColumnArray` | Nested array: `offsets` + a child `IColumn` of the element type. |
| `ColumnTuple` | Heterogeneous fixed-size tuple: vector of child columns. |
| `ColumnMap` | `ColumnArray(ColumnTuple(k, v))` under the hood. |
| `ColumnNullable` | Nested column + a `UInt8` null map. |
| `ColumnLowCardinality` | Dictionary encoding: a unique-values dictionary column + an index column. |
| `ColumnConst` | A virtual column wrapping one value repeated `size()` times. Avoids materialization when an expression evaluates to a constant. |
| `ColumnSparse` | Stores only non-default values + their positions. |
| `ColumnObject`, `ColumnVariant`, `ColumnDynamic` | Newer schema-less / variant types. |

`ColumnConst` and `ColumnSparse` are virtual wrappers — functions either special-case them or call `convertToFullColumnIfConst`/`Sparse` to materialize.

### Why immutable

Pipelines fork (e.g. a `Resize` step splits one stream into N), and the same `ColumnPtr` is passed to many downstream processors. If columns were mutable, every share would need defensive copying or locking. COW lets *reads* be free and *writes* be cheap-when-possible — the common pipeline pattern is "build a `MutableColumnPtr` in one place, hand it off as a `ColumnPtr`, never touch it again."

## `Field` — the slow path

[src/Core/Field.h](../src/Core/Field.h) is a discriminated union (`Types::Which` tag + aligned storage) holding one value of any supported type. It exists because some operations are genuinely scalar — default values for `INSERT` ... `VALUES`, individual elements of literal tuples, comparisons during planning.

The comment in the header is blunt: *"Prefer to use chunks of columns instead of single values."* Extracting a `Field` from a `ColumnString` allocates a `std::string`; doing it in a per-row loop is how you accidentally turn a vectorized query into a single-threaded one. Most of the codebase touches `Field` only at AST/planning time, never in the inner loop.

## `IDataType` — type metadata

[src/DataTypes/IDataType.h](../src/DataTypes/IDataType.h) is the *schema-level* description of a column. One `DataTypePtr` is shared by every column of that type, everywhere.

Key methods:

- `createColumn()` — manufacture an empty `MutableColumnPtr` of the right kind.
- `getDefault()` — the default `Field` value (for missing columns, `Nullable` nulls, etc.).
- `getSerialization()` ([src/DataTypes/Serializations/ISerialization.h](../src/DataTypes/Serializations/ISerialization.h)) — returns the encoder/decoder for binary, text, JSON, etc. The serialization layer is where sparse encoding, subcolumns (e.g. `Nullable.null`, `Array.size0`), and version-specific tweaks live.
- `getSubcolumnType` / `getSubcolumnNames` — many compound types expose virtual subcolumns that storage and the planner can read directly (e.g. you can read just `Tuple.x` from disk without materializing the tuple).

**`IDataType` is metadata; `IColumn` is storage.** Don't put runtime data on the type, and don't put type-system logic on the column.

## `Block` — the schema-carrying container

[src/Core/Block.h](../src/Core/Block.h) is a vector of `ColumnWithTypeAndName` ([src/Core/ColumnWithTypeAndName.h](../src/Core/ColumnWithTypeAndName.h)): each element is `{ColumnPtr, DataTypePtr, String name}` plus a hash index by name and a `BlockInfo` ([src/Core/BlockInfo.h](../src/Core/BlockInfo.h)) for aggregation metadata (`is_overflows`, `bucket_num`).

Two flavors:

- **Data block** — columns have rows; this is real data moving through the system.
- **Header block** — columns are *empty* (or `nullptr`) but types and names are populated. Headers describe pipeline schemas without allocating data. Every `IProcessor` exposes a header on each port.

`Block` is the natural unit in the SQL / planning layers (where you need names). Once execution starts, processors prefer `Chunk`.

## `Chunk` — the pipeline-internal container

[src/Processors/Chunk.h](../src/Processors/Chunk.h) is what actually flows between processors at runtime: `Columns columns` + `UInt64 num_rows` + an optional `ChunkInfoCollection` of attached metadata.

Differences from `Block`:

- **No names, no types.** Those are known from the port's header; carrying them on every chunk would be redundant overhead.
- **Move-only** (copy constructor and copy-assignment are deleted). Ownership is explicit; nobody can accidentally share a chunk between two processors.
- **Equal-length invariant.** All columns in a chunk have the same number of rows.
- **Extensible info.** `ChunkInfoCollection` is how things like async-insert deduplication tokens, two-level aggregation bucket numbers, and aggregated-state markers ride along without polluting the chunk's main structure.

A useful mental model: `Block` is for compile-time/plan-time; `Chunk` is for runtime. Sources turn the header (Block) into runtime data (Chunk).

## `NamesAndTypes` and `ColumnsDescription`

Two schema descriptors that show up in storage and planning:

- [src/Core/NamesAndTypes.h](../src/Core/NamesAndTypes.h) — `Vector<{name, DataTypePtr}>`. Used wherever you want "a list of columns" without actual data: expression results, plan-step inputs, etc.
- [src/Storages/ColumnsDescription.h](../src/Storages/ColumnsDescription.h) — the richer table-schema descriptor: columns with their defaults (`DEFAULT`, `MATERIALIZED`, `ALIAS`, `EPHEMERAL`), comments, codecs, TTLs, statistics, virtual columns. This is what `IStorage::getInMemoryMetadata` exposes.

## Contributor checklist

If you're modifying anything in this layer, keep these in mind:

1. **Never mutate a const `IColumn`.** Use `IColumn::mutate(std::move(ptr))`; the returned `MutableColumnPtr` is yours to write to.
2. **Avoid `Field` in hot loops.** If you find yourself writing `for (size_t i = 0; i < rows; ++i) { Field f = col[i]; ... }`, you're on the slow path. Use the column's bulk methods instead.
3. **Handle `ColumnConst` and `ColumnLowCardinality` wrappers.** Functions either special-case them or unwrap them at the top. Forgetting to do so produces correctness bugs (wrong row count) or terrible performance (materializing a 65k-row const).
4. **Don't compare columns by pointer for equality of contents.** COW means two distinct pointers can point to identical data, and vice versa.
5. **`Block` and `Chunk` are not interchangeable.** Source processors convert; transforms operate on `Chunk`; output formats see whatever they declared on their input port.
