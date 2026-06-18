//! A deliberately minimal, dependency-free Apache Parquet writer.
//!
//! Parquet is a columnar format whose footer metadata is encoded with the
//! Thrift *compact* protocol. A full encoder is large; we implement only the
//! slice the monitor needs and nothing more:
//!
//!   * columns are always REQUIRED (no nulls), so data pages carry no
//!     repetition/definition levels — just the values;
//!   * two physical types — INT64 and BYTE_ARRAY (annotated UTF8 for strings);
//!   * PLAIN value encoding;
//!   * a single row group with one DATA_PAGE per column.
//!
//! Page compression is pluggable: the caller may pass a `Compressor` (the
//! monitor backs it with the system `zstd` binary), in which case each page is
//! compressed and the chunk is tagged with the ZSTD codec; with no compressor
//! the codec is UNCOMPRESSED. The writer itself stays free of any compression
//! or process-spawning code — it just calls the callback.
//!
//! That is enough to produce files that DuckDB, pandas/pyarrow, and Polars read
//! as ordinary tables. The trade-offs (no dictionary/statistics, everything in
//! one row group) are fine for this tool's small exports; see
//! docs/design-decisions.md. The format reference is the canonical
//! `parquet.thrift`: https://github.com/apache/parquet-format/blob/master/src/main/thrift/parquet.thrift

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const created_by = "fable-monitor";

/// Logical column type. `int` maps to the Parquet INT64 physical type; `str`
/// maps to BYTE_ARRAY annotated as UTF8.
pub const ColType = enum { int, str };

pub const Column = struct {
    name: []const u8,
    type: ColType,
};

/// A single cell. The active field must match its column's `ColType`.
pub const Value = union(ColType) {
    int: i64,
    str: []const u8,
};

/// Pluggable page compressor. `func` takes the raw page bytes and returns the
/// compressed bytes (allocated so they outlive the call). When a `Compressor`
/// is supplied to `writeTable`, pages are compressed and the column chunks are
/// tagged ZSTD; the monitor's implementation shells out to the `zstd` binary.
pub const Compressor = struct {
    context: *anyopaque,
    func: *const fn (*anyopaque, []const u8) anyerror![]const u8,

    fn run(self: Compressor, data: []const u8) ![]const u8 {
        return self.func(self.context, data);
    }
};

// --- Parquet enum values (from parquet.thrift) -----------------------------
const pt_int64 = 2; // Type.INT64
const pt_byte_array = 6; // Type.BYTE_ARRAY
const rep_required = 0; // FieldRepetitionType.REQUIRED
const conv_utf8 = 0; // ConvertedType.UTF8
const enc_plain = 0; // Encoding.PLAIN
const enc_rle = 3; // Encoding.RLE (named for the level encodings; unused here)
const codec_uncompressed = 0; // CompressionCodec.UNCOMPRESSED
const codec_zstd = 6; // CompressionCodec.ZSTD
const page_data = 0; // PageType.DATA_PAGE

// --- Thrift compact protocol field types -----------------------------------
const tc_i32 = 5;
const tc_i64 = 6;
const tc_binary = 8;
const tc_list = 9;
const tc_struct = 12;

const magic = "PAR1";

/// Sizes recorded for a column chunk as it is written, so the footer can
/// describe and point at it.
const ChunkInfo = struct {
    offset: u64, // byte offset of the data page (header start)
    compressed: u64, // on-disk size: page header + stored (possibly compressed) data
    uncompressed: u64, // page header + raw PLAIN data
};

/// Encode `columns`/`rows` (row-major) as a Parquet file and write it to
/// `path` under `dir`. Each row must have exactly `columns.len` values whose
/// active union fields match the column types. When `compressor` is non-null,
/// data pages are compressed with it and the chunks are tagged ZSTD.
pub fn writeTable(
    a: Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    columns: []const Column,
    rows: []const []const Value,
    compressor: ?Compressor,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, magic);

    const chunks = try a.alloc(ChunkInfo, columns.len);

    // One data page per column. Encode the values (PLAIN), optionally compress,
    // then a page header followed by the (compressed) bytes.
    for (columns, 0..) |col, ci| {
        const plain = try plainColumn(a, col, rows, ci);
        const stored: []const u8 = if (compressor) |c| try c.run(plain) else plain;

        const start = buf.items.len;
        try encodePageHeader(&buf, a, @intCast(rows.len), @intCast(plain.len), @intCast(stored.len));
        const header_len = buf.items.len - start;
        try buf.appendSlice(a, stored);

        chunks[ci] = .{
            .offset = start,
            .compressed = buf.items.len - start,
            .uncompressed = header_len + plain.len,
        };
    }

    const codec: i32 = if (compressor != null) codec_zstd else codec_uncompressed;
    const footer_start = buf.items.len;
    try encodeFileMetaData(&buf, a, columns, @intCast(rows.len), chunks, codec);
    try appendIntLe(&buf, a, u32, @intCast(buf.items.len - footer_start));
    try buf.appendSlice(a, magic);

    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);
}

/// PLAIN-encode one column's values across all rows.
fn plainColumn(a: Allocator, col: Column, rows: []const []const Value, ci: usize) ![]u8 {
    var page: std.ArrayList(u8) = .empty;
    for (rows) |r| switch (col.type) {
        .int => try appendIntLe(&page, a, i64, r[ci].int),
        .str => {
            const s = r[ci].str;
            try appendIntLe(&page, a, u32, @intCast(s.len));
            try page.appendSlice(a, s);
        },
    };
    return page.items;
}

fn appendIntLe(buf: *std.ArrayList(u8), a: Allocator, comptime T: type, value: T) !void {
    var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try buf.appendSlice(a, &bytes);
}

// --- Thrift compact encoder -------------------------------------------------

/// Streaming Thrift compact-protocol writer. Field ids inside a struct are
/// delta-encoded against the previous field, so we keep a small stack of the
/// "last field id" for each open struct.
const Compact = struct {
    buf: *std.ArrayList(u8),
    a: Allocator,
    last_id: [16]i16 = undefined,
    depth: usize = 0,

    fn beginStruct(self: *Compact) void {
        self.last_id[self.depth] = 0;
        self.depth += 1;
    }

    fn endStruct(self: *Compact) !void {
        try self.byte(0x00); // STOP
        self.depth -= 1;
    }

    fn byte(self: *Compact, b: u8) !void {
        try self.buf.append(self.a, b);
    }

    fn varint(self: *Compact, v: u64) !void {
        var x = v;
        while (x >= 0x80) {
            try self.byte(@intCast((x & 0x7f) | 0x80));
            x >>= 7;
        }
        try self.byte(@intCast(x));
    }

    fn fieldHeader(self: *Compact, id: i16, tc: u8) !void {
        const last = self.last_id[self.depth - 1];
        const delta = id - last;
        if (delta > 0 and delta <= 15) {
            try self.byte((@as(u8, @intCast(delta)) << 4) | tc);
        } else {
            try self.byte(tc);
            try self.varint(zigzag(id));
        }
        self.last_id[self.depth - 1] = id;
    }

    fn i32Field(self: *Compact, id: i16, value: i32) !void {
        try self.fieldHeader(id, tc_i32);
        try self.varint(zigzag(value));
    }

    fn i64Field(self: *Compact, id: i16, value: i64) !void {
        try self.fieldHeader(id, tc_i64);
        try self.varint(zigzag(value));
    }

    fn binaryField(self: *Compact, id: i16, bytes: []const u8) !void {
        try self.fieldHeader(id, tc_binary);
        try self.binary(bytes);
    }

    fn binary(self: *Compact, bytes: []const u8) !void {
        try self.varint(bytes.len);
        try self.buf.appendSlice(self.a, bytes);
    }

    /// List header: size in the high nibble (or 0xF + varint when >= 15) and
    /// element type in the low nibble.
    fn listHeader(self: *Compact, count: usize, elem_type: u8) !void {
        if (count < 15) {
            try self.byte((@as(u8, @intCast(count)) << 4) | elem_type);
        } else {
            try self.byte(0xF0 | elem_type);
            try self.varint(count);
        }
    }
};

/// Zigzag-encode a signed value to the unsigned form Thrift varints expect.
fn zigzag(value: anytype) u64 {
    const v: i64 = value;
    const uv: u64 = @bitCast(v);
    const sign: u64 = @bitCast(v >> 63);
    return (uv << 1) ^ sign;
}

fn encodePageHeader(
    buf: *std.ArrayList(u8),
    a: Allocator,
    num_values: i32,
    uncompressed_size: i32,
    compressed_size: i32,
) !void {
    var c = Compact{ .buf = buf, .a = a };
    c.beginStruct(); // PageHeader
    try c.i32Field(1, page_data); // type
    try c.i32Field(2, uncompressed_size); // uncompressed_page_size
    try c.i32Field(3, compressed_size); // compressed_page_size
    try c.fieldHeader(5, tc_struct); // data_page_header
    c.beginStruct(); // DataPageHeader
    try c.i32Field(1, num_values);
    try c.i32Field(2, enc_plain); // encoding
    try c.i32Field(3, enc_rle); // definition_level_encoding (no levels: REQUIRED)
    try c.i32Field(4, enc_rle); // repetition_level_encoding (no levels: REQUIRED)
    try c.endStruct();
    try c.endStruct();
}

fn encodeFileMetaData(
    buf: *std.ArrayList(u8),
    a: Allocator,
    columns: []const Column,
    num_rows: i64,
    chunks: []const ChunkInfo,
    codec: i32,
) !void {
    var c = Compact{ .buf = buf, .a = a };
    c.beginStruct(); // FileMetaData
    try c.i32Field(1, 1); // version

    // schema: a root group element followed by one leaf per column.
    try c.fieldHeader(2, tc_list);
    try c.listHeader(columns.len + 1, tc_struct);
    try schemaElement(&c, null, null, "schema", @intCast(columns.len), null);
    for (columns) |col| switch (col.type) {
        .int => try schemaElement(&c, pt_int64, rep_required, col.name, null, null),
        .str => try schemaElement(&c, pt_byte_array, rep_required, col.name, null, conv_utf8),
    };

    try c.i64Field(3, num_rows);

    // row_groups: exactly one.
    try c.fieldHeader(4, tc_list);
    try c.listHeader(1, tc_struct);
    c.beginStruct(); // RowGroup
    try c.fieldHeader(1, tc_list); // columns
    try c.listHeader(columns.len, tc_struct);
    var total: i64 = 0;
    for (columns, 0..) |col, ci| {
        total += @intCast(chunks[ci].compressed);
        try columnChunk(&c, col, chunks[ci], num_rows, codec);
    }
    try c.i64Field(2, total); // total_byte_size
    try c.i64Field(3, num_rows); // num_rows
    try c.endStruct(); // RowGroup

    try c.binaryField(6, created_by);
    try c.endStruct(); // FileMetaData
}

fn schemaElement(
    c: *Compact,
    phys_type: ?i32,
    repetition: ?i32,
    name: []const u8,
    num_children: ?i32,
    converted: ?i32,
) !void {
    c.beginStruct();
    if (phys_type) |t| try c.i32Field(1, t);
    if (repetition) |r| try c.i32Field(3, r);
    try c.binaryField(4, name);
    if (num_children) |n| try c.i32Field(5, n);
    if (converted) |cv| try c.i32Field(6, cv);
    try c.endStruct();
}

fn columnChunk(c: *Compact, col: Column, chunk: ChunkInfo, num_values: i64, codec: i32) !void {
    const phys: i32 = if (col.type == .int) pt_int64 else pt_byte_array;
    c.beginStruct(); // ColumnChunk
    try c.i64Field(2, @intCast(chunk.offset)); // file_offset
    try c.fieldHeader(3, tc_struct); // meta_data
    c.beginStruct(); // ColumnMetaData
    try c.i32Field(1, phys); // type
    try c.fieldHeader(2, tc_list); // encodings
    try c.listHeader(1, tc_i32);
    try c.varint(zigzag(@as(i32, enc_plain)));
    try c.fieldHeader(3, tc_list); // path_in_schema
    try c.listHeader(1, tc_binary);
    try c.binary(col.name);
    try c.i32Field(4, codec); // codec
    try c.i64Field(5, num_values); // num_values
    try c.i64Field(6, @intCast(chunk.uncompressed)); // total_uncompressed_size
    try c.i64Field(7, @intCast(chunk.compressed)); // total_compressed_size
    try c.i64Field(9, @intCast(chunk.offset)); // data_page_offset
    try c.endStruct(); // ColumnMetaData
    try c.endStruct(); // ColumnChunk
}

// ---------------------------------------------------------------------------
// Tests for the encoders. Parsing Parquet back is out of scope for std-only
// Zig, so format correctness is validated end-to-end by reading an exported
// file with an external reader (see docs/data-export.md); here we pin the
// low-level encodings that the rest builds on.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "zigzag matches the Thrift definition" {
    try testing.expectEqual(@as(u64, 0), zigzag(@as(i32, 0)));
    try testing.expectEqual(@as(u64, 1), zigzag(@as(i32, -1)));
    try testing.expectEqual(@as(u64, 2), zigzag(@as(i32, 1)));
    try testing.expectEqual(@as(u64, 3), zigzag(@as(i32, -2)));
    try testing.expectEqual(@as(u64, 4), zigzag(@as(i64, 2)));
}

test "varint encodes multi-byte values little-endian base-128" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    var c = Compact{ .buf = &buf, .a = a };
    try c.varint(300); // 300 = 0b100101100 -> 0xAC 0x02
    try testing.expectEqualSlices(u8, &.{ 0xAC, 0x02 }, buf.items);
}

test "field header uses delta encoding then falls back to zigzag id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    var c = Compact{ .buf = &buf, .a = a };
    c.beginStruct();
    try c.fieldHeader(1, tc_i32); // delta 1 -> (1<<4)|5 = 0x15
    try c.fieldHeader(9, tc_i64); // delta 8 -> (8<<4)|6 = 0x86
    try c.fieldHeader(30, tc_i32); // delta 21 > 15 -> 0x05 then zigzag(30)=60=0x3C
    try testing.expectEqualSlices(u8, &.{ 0x15, 0x86, 0x05, 0x3C }, buf.items);
}

// A no-op compressor used to exercise the compressed code path without a real
// codec: it echoes its input, so "compressed" == "uncompressed" byte-for-byte.
fn identityCompress(_: *anyopaque, data: []const u8) anyerror![]const u8 {
    return data;
}

test "writeTable frames the file with PAR1 and a little-endian footer length" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const columns = [_]Column{
        .{ .name = "n", .type = .int },
        .{ .name = "s", .type = .str },
    };
    const rows = [_][]const Value{
        &.{ .{ .int = 7 }, .{ .str = "hi" } },
        &.{ .{ .int = -3 }, .{ .str = "" } },
    };

    // Reproduce writeTable's framing in-memory (it needs an Io/Dir to write a
    // file; the byte layout is identical). Exercise the compressed path via an
    // identity compressor so the page-size bookkeeping is still hit.
    var dummy: u8 = 0;
    const compressor = Compressor{ .context = &dummy, .func = identityCompress };

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, magic);
    const chunks = try a.alloc(ChunkInfo, columns.len);
    for (&columns, 0..) |col, ci| {
        const plain = try plainColumn(a, col, &rows, ci);
        const stored = try compressor.run(plain);
        const start = buf.items.len;
        try encodePageHeader(&buf, a, @intCast(rows.len), @intCast(plain.len), @intCast(stored.len));
        const header_len = buf.items.len - start;
        try buf.appendSlice(a, stored);
        chunks[ci] = .{
            .offset = start,
            .compressed = buf.items.len - start,
            .uncompressed = header_len + plain.len,
        };
    }
    const footer_start = buf.items.len;
    try encodeFileMetaData(&buf, a, &columns, @intCast(rows.len), chunks, codec_zstd);
    const footer_len = buf.items.len - footer_start;
    try appendIntLe(&buf, a, u32, @intCast(footer_len));
    try buf.appendSlice(a, magic);

    try testing.expectEqualSlices(u8, magic, buf.items[0..4]);
    try testing.expectEqualSlices(u8, magic, buf.items[buf.items.len - 4 ..]);
    const stored_len = std.mem.readInt(u32, buf.items[buf.items.len - 8 ..][0..4], .little);
    try testing.expectEqual(@as(u32, @intCast(footer_len)), stored_len);
}
