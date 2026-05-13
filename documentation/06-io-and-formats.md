# IO Layer and Formats

ClickHouse rolls its own buffer hierarchy instead of using C++ iostreams or stdio, and its own format layer that plugs directly into the processor pipeline. This file covers both.

## The buffer hierarchy

[src/IO/BufferBase.h](../../src/IO/BufferBase.h) is the common base. Every read/write buffer exposes a contiguous in-memory window — the **working buffer** — and a cursor `pos` inside it.

- [src/IO/ReadBuffer.h](../../src/IO/ReadBuffer.h) — abstract reader. Subclasses implement `nextImpl()`: refill the working buffer from the source and return whether more data exists. Everything else — `read(byte)`, `read(out, n)`, `eof()`, `position()`, `peek()` — is implemented on top.
- [src/IO/WriteBuffer.h](../../src/IO/WriteBuffer.h) — abstract writer. Subclasses implement `nextImpl()`: flush the working buffer to the destination and reset `pos`.
- [src/IO/ReadBufferFromFileBase.h](../../src/IO/ReadBufferFromFileBase.h), `SeekableReadBuffer`, `IReadableWriteBuffer` — interface extensions for seekable / writable-and-readable buffers.

### Why not std iostreams

Three reasons:

1. **Buffer ownership is explicit.** Parsing routines write directly into the buffer's exposed memory, no copies. Format readers can look ahead in `O(1)` without allocating.
2. **One virtual call per chunk, not per byte.** `nextImpl()` fires once per refill (default 1 MiB). Inline helpers handle the byte-level path entirely in registers.
3. **First-class seek / prefetch / size knowledge.** `seek()`, `setReadUntilPosition()` (so an S3 reader only fetches what's needed), `getFileSize()`, `tryGetFileSize()`, `prefetch()`, `getNumBytesToCopy()`. iostreams don't model any of this cleanly.

### Concrete buffers

Selected examples; everything is in [src/IO/](../../src/IO/) or its `S3/`, `Azure/`, `HDFS/` subfolders.

| Buffer | Source/destination |
| --- | --- |
| `ReadBufferFromFile` / `ReadBufferFromFileDescriptor` | Local files. The descriptor variant is the lower-level one; both honor `O_DIRECT` (the open flag is passed through, and the buffer's `required_alignment` is set accordingly so reads land on aligned memory). The `local_filesystem_read_method` setting picks the actual syscall (`read`, `pread`, `io_uring`, ...). |
| `ReadBufferFromS3` | S3 GET requests. Knows ranges (`Range: bytes=...`), can re-issue with backoff, supports `setReadUntilPosition` for partial fetches. |
| `ReadBufferFromAzureBlobStorage`, `ReadBufferFromWebServer`, `ReadBufferFromHDFS` | Other object stores. |
| `AsynchronousReadBufferFromFile` | Wraps a base reader; issues `prefetch()` calls to a background reader pool so I/O overlaps compute. |
| `CompressedReadBuffer` | Wraps an inner buffer; reads compressed blocks (LZ4, ZSTD, ...) and exposes the decompressed bytes. The compressed block layout is what `.mrk` files index into. |
| `CachedOnDiskReadBufferFromFile` | The filesystem cache layer: serves reads from local disk cache, falls back to the wrapped remote reader on miss. |
| `HashingReadBuffer` / `HashingWriteBuffer` | Compute a `CityHash128` of everything passing through. Used to verify part checksums (`checksums.txt`). |
| `LimitReadBuffer`, `BoundedReadBuffer` | Read at most N bytes. |

Buffers compose by ownership: a `ReadBufferFromS3` wrapped in a `CachedOnDiskReadBufferFromFile` wrapped in a `CompressedReadBuffer` is a perfectly normal MergeTree read stack.

## Compression

[src/Compression/](../../src/Compression/) defines the codec registry. `CompressionCodecFactory` produces a `ICompressionCodec` by name; codecs handle compress/decompress of individual blocks. Common codecs: `LZ4` (default), `ZSTD`, `Delta`, `DoubleDelta`, `Gorilla`, `T64`, `FPC`. Codecs are composable per column (`column Codec(Delta, ZSTD)`); the writer chains them.

The on-disk block format is `<header><compressed bytes>`, where the header has the codec id, compressed size, and uncompressed size. `CompressedReadBuffer::seek(offset_in_compressed, offset_in_uncompressed)` is what `.mrk` files drive.

## Formats

A **format** is a serialization for `Block`s/`Chunk`s. The format layer plugs directly into the processor model: a format reader is an `ISource`, a format writer is an `IOutputFormat`. The registry is [src/Formats/FormatFactory.h](../../src/Formats/FormatFactory.h).

### Reading: `IInputFormat` and `IRowInputFormat`

- [src/Processors/Formats/IInputFormat.h](../../src/Processors/Formats/IInputFormat.h) — `IInputFormat` extends `ISource`. It owns a `ReadBuffer` and `generate()` produces `Chunk`s. Block-oriented formats (`Native`, `Parquet`, `ORC`, `Arrow`) implement this directly: they read a whole block of column data at once.
- [src/Processors/Formats/IRowInputFormat.h](../../src/Processors/Formats/IRowInputFormat.h) — `IRowInputFormat` is the helper for row-oriented formats (`TSV`, `CSV`, `JSONEachRow`, `Values`, `Protobuf`, `RowBinary`, ...). Subclasses implement `readRow(MutableColumns &, RowReadExtension &)`. The base class batches rows into chunks of `max_block_size` and handles error tolerance (`input_format_allow_errors_num/ratio`).

**Parallel parsing.** For some formats (`TSV`, `CSV`, `JSONEachRow`, ...) a registered `FileSegmentationEngine` knows how to find safe split points (e.g. end-of-line). With `input_format_parallel_parsing = 1` ([src/Formats/ParallelParsingInputFormat.h](../../src/Processors/Formats/Impl/ParallelParsingInputFormat.h)), the IO thread chunks the input by these split points and dispatches parsing to a worker pool — N threads decoding the same file in parallel. The reassembler emits chunks in the original order.

**Schema inference.** Many formats register a `SchemaReader` so `SELECT * FROM s3(..., 'JSONEachRow')` (no explicit structure) just works.

### Writing: `IOutputFormat`

[src/Processors/IOutputFormat.h](../../src/Processors/Formats/IOutputFormat.h) — `IOutputFormat` is an `IProcessor` with three input ports: **Main**, **Totals** (the result of `WITH TOTALS`), and **Extremes** (`SET extremes = 1` adds min/max rows). It owns a `WriteBuffer` and `consume(Chunk)` / `consumeTotals(Chunk)` / `consumeExtremes(Chunk)` write to it.

A few notable formats:

| Format | Notes |
| --- | --- |
| `Native` | ClickHouse's internal binary block format. What flows between servers on the native TCP protocol. Versioned, extensible (compressed-marshalled columns plus type/name metadata). Implemented by [src/Formats/NativeReader.h](../../src/Formats/NativeReader.h) / `NativeWriter.h`. |
| `RowBinary`, `RowBinaryWithNamesAndTypes` | Compact row-per-row binary. Useful for inter-tool integration. |
| `TSV`, `CSV`, `TSVRaw`, `CustomSeparated` | Text row formats. |
| `JSONEachRow`, `JSONCompactEachRow`, `JSONStringsEachRow` | Newline-delimited JSON variants. |
| `Pretty`, `PrettyCompact`, `PrettySpace` | Tables formatted for terminals. |
| `Parquet`, `ORC`, `Arrow`, `ArrowStream`, `Avro` | Columnar/external formats via Arrow / ORC libraries. |
| `Protobuf`, `ProtobufSingle`, `CapnProto` | Schema-driven binary. |
| `Template`, `Regexp` | User-defined text shapes. |

### Two key roles formats play

1. **Client-server boundary.** What the user typed `FORMAT XYZ` for. The pipeline ends in this format and it writes to the connection.
2. **Storage I/O.** `StorageFile`, `StorageS3`, `StorageURL`, and integration engines all delegate their reads to an `IInputFormat` over a `ReadBuffer` to the underlying file. There is no separate "reading from S3" code path; it's the format layer reading from `ReadBufferFromS3`. Same with writes.

The result is that adding a new format gives you, for free: client output, `clickhouse-client --format`, file-based ingestion (`INSERT INTO ... FORMAT ...`), file-based tables (`StorageFile`), and S3/URL access.

## How the pipeline reads from a file/URL/S3 table

For a query like `SELECT * FROM s3('https://.../file.parquet', 'Parquet')`:

1. Table function builds a `StorageObjectStorage` (or similar).
2. Its `read()` instantiates one or more `StorageS3Source` processors. Each holds:
   - A `ReadBufferFromS3` (possibly wrapped in cache and async-prefetch buffers).
   - An `IInputFormat` configured for `Parquet` reading from that buffer.
3. The source's `generate()` pulls a `Chunk` from the format, which in turn pulls bytes from the read buffer, which in turn issues HTTP GETs.

The whole stack is composable because each layer only knows about the interface below it. You can swap `ReadBufferFromS3` for `ReadBufferFromFile` and the format doesn't notice.

## Performance notes

- **Buffer sizes matter.** Default working buffer is 1 MiB for files, larger for object storage. Settings: `max_read_buffer_size`, `remote_filesystem_read_method`, `remote_filesystem_read_prefetch`.
- **Async I/O is opt-in but on by default for object storage.** `AsynchronousReadBufferFromFile` and `ThreadPoolReader` overlap read and decompress. Knob: `threadpool_reader_pool_size`.
- **Filesystem cache.** Configured per-disk; transparent to the buffer stack via `CachedOnDiskReadBuffer*`. Sized via `<cache>` section of disk config. `SYSTEM DROP FILESYSTEM CACHE` clears it.
- **Parallel parsing helps text formats.** If a single-shard ingestion is bottlenecked on CPU, increase `max_threads` and check `input_format_parallel_parsing` is on.
