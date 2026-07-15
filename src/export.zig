//! Parquet export: project the NDJSON observation log and the current state
//! file into Parquet tables under an output directory. Each source is
//! independent; a missing input is logged and skipped rather than aborting.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parquet = @import("parquet.zig");
const zstd = @import("zstd.zig");
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;
const events = @import("events.zig");
const Event = events.Event;
const state = @import("state.zig");

/// `fable-monitor export [out_dir]`: project the history log and the current
/// state file into Parquet tables under `out_dir`. Each source is independent;
/// a missing input is logged and skipped rather than aborting the others.
pub fn exportParquet(ctx: *Context, out_dir: []const u8) !void {
    try Io.Dir.cwd().createDirPath(ctx.io, out_dir);
    log("exporting Parquet into {s}/", .{out_dir});
    try exportEvents(ctx, out_dir);
    try exportState(ctx, out_dir);
}

/// Build a one-row slice of Parquet values in the arena.
fn row(a: Allocator, values: []const parquet.Value) ![]const parquet.Value {
    return a.dupe(parquet.Value, values);
}

fn exportEvents(ctx: *Context, out_dir: []const u8) !void {
    const a = ctx.arena;
    const data = events.readLog(ctx.io, a, ctx.log_path) catch {
        log("no observation log at {s}; skipping events.parquet", .{ctx.log_path});
        return;
    };

    const columns = [_]parquet.Column{
        .{ .name = "observed_at", .type = .str },
        .{ .name = "epoch_ms", .type = .int },
        .{ .name = "source_id", .type = .str },
        .{ .name = "source_label", .type = .str },
        .{ .name = "source_kind", .type = .str },
        .{ .name = "event", .type = .str },
        .{ .name = "document_number", .type = .str },
        .{ .name = "title", .type = .str },
        .{ .name = "publication_date", .type = .str },
        .{ .name = "url", .type = .str },
        .{ .name = "detail", .type = .str },
        // v2 columns (default to empty/0 for rows written by older builds).
        .{ .name = "tier", .type = .int },
        .{ .name = "confidence", .type = .str },
        .{ .name = "event_identity", .type = .str },
        .{ .name = "published_at", .type = .str },
        .{ .name = "published_epoch_ms", .type = .int },
        .{ .name = "fetch_ms", .type = .int },
        .{ .name = "http_status", .type = .int },
    };

    var rows: std.ArrayList([]const parquet.Value) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(Event, a, trimmed, .{ .ignore_unknown_fields = true }) catch |err| {
            log("export: skipping malformed log line ({s})", .{@errorName(err)});
            continue;
        };
        const e = parsed.value;
        try rows.append(a, try row(a, &.{
            .{ .str = e.observed_at },
            .{ .int = e.epoch_ms },
            .{ .str = e.source_id },
            .{ .str = e.source_label },
            .{ .str = e.source_kind },
            .{ .str = e.event },
            .{ .str = e.document_number },
            .{ .str = e.title },
            .{ .str = e.publication_date },
            .{ .str = e.url },
            .{ .str = e.detail },
            .{ .int = e.tier },
            .{ .str = e.confidence },
            .{ .str = e.event_identity },
            .{ .str = e.published_at },
            .{ .int = e.published_epoch_ms },
            .{ .int = e.fetch_ms },
            .{ .int = e.http_status },
        }));
    }

    var cc = zstd.CompressorCtx{ .io = ctx.io, .arena = a };
    const path = try std.fmt.allocPrint(a, "{s}/events.parquet", .{out_dir});
    try parquet.writeTable(a, ctx.io, Io.Dir.cwd(), path, &columns, rows.items, zstd.compressor(&cc));
    log("wrote {s} ({d} rows)", .{ path, rows.items.len });
}

fn exportState(ctx: *Context, out_dir: []const u8) !void {
    const a = ctx.arena;
    const st = state.loadState(ctx) catch |err| {
        log("no readable state file at {s} ({s}); skipping state tables", .{ ctx.state_path, @errorName(err) });
        return;
    };
    var cc = zstd.CompressorCtx{ .io = ctx.io, .arena = a };
    const compressor = zstd.compressor(&cc);

    {
        const columns = [_]parquet.Column{.{ .name = "document_number", .type = .str }};
        var rows: std.ArrayList([]const parquet.Value) = .empty;
        for (st.federal_register_seen) |d| {
            try rows.append(a, try row(a, &.{.{ .str = d }}));
        }
        const path = try std.fmt.allocPrint(a, "{s}/state_seen.parquet", .{out_dir});
        try parquet.writeTable(a, ctx.io, Io.Dir.cwd(), path, &columns, rows.items, compressor);
        log("wrote {s} ({d} rows)", .{ path, rows.items.len });
    }

    {
        const columns = [_]parquet.Column{
            .{ .name = "id", .type = .str },
            .{ .name = "hash", .type = .str },
        };
        var rows: std.ArrayList([]const parquet.Value) = .empty;
        for (st.keyword_hashes) |kh| {
            try rows.append(a, try row(a, &.{ .{ .str = kh.id }, .{ .str = kh.hash } }));
        }
        const path = try std.fmt.allocPrint(a, "{s}/state_keyword_hashes.parquet", .{out_dir});
        try parquet.writeTable(a, ctx.io, Io.Dir.cwd(), path, &columns, rows.items, compressor);
        log("wrote {s} ({d} rows)", .{ path, rows.items.len });
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Read a whole file under the cwd into the arena; small helper for assertions.
fn readWhole(io: Io, a: Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
}

/// A Parquet file is framed by the "PAR1" magic at both ends. Assert the file
/// exists, is non-trivial, and carries the magic in both positions.
fn expectParquetFile(io: Io, a: Allocator, path: []const u8) !void {
    const bytes = try readWhole(io, a, path);
    // Magic (4) at head + tail, plus a 4-byte footer length between them.
    try testing.expect(bytes.len > 12);
    try testing.expectEqualStrings("PAR1", bytes[0..4]);
    try testing.expectEqualStrings("PAR1", bytes[bytes.len - 4 ..]);
}

test "exportParquet writes the three framed Parquet tables from a seeded log and state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;

    const state_path = ".test-fable-monitor-export-happy-state.jsonl.zst";
    const log_path = ".test-fable-monitor-export-happy-log.jsonl";
    const out_dir = ".test-fable-monitor-export-happy-out";

    // Clean up every artifact the log/state/parquet paths can create. The log
    // path spawns sibling `.segments`/`.manifest*` files and per-path locks.
    defer {
        Io.Dir.cwd().deleteTree(io, out_dir) catch {};
        Io.Dir.cwd().deleteTree(io, log_path ++ ".segments") catch {};
        Io.Dir.cwd().deleteFile(io, log_path) catch {};
        Io.Dir.cwd().deleteFile(io, log_path ++ ".manifest") catch {};
        Io.Dir.cwd().deleteFile(io, log_path ++ ".manifest.backup") catch {};
        Io.Dir.cwd().deleteFile(io, log_path ++ ".lock") catch {};
        Io.Dir.cwd().deleteFile(io, state_path) catch {};
        Io.Dir.cwd().deleteFile(io, state_path ++ ".lock") catch {};
    }

    var ctx = Context{
        .io = io,
        .arena = a,
        .state_path = state_path,
        .log_path = log_path,
        .notify_cmd = null,
        .observed_at = "2026-07-04T00:00:00Z",
        .epoch_ms = 1_000,
    };

    // Seed a small observation log through the real durable append path.
    const seeded = [_]Event{
        .{
            .observed_at = "2026-07-04T00:00:00Z",
            .epoch_ms = 1_000,
            .source_id = "federal_register",
            .source_label = "Federal Register",
            .source_kind = "document_watch",
            .event = events.ev_new_document,
            .document_number = "2026-001",
            .title = "Sample Rule",
            .publication_date = "2026-07-04",
            .url = "https://example.test/doc",
            .detail = "seed",
            .tier = 1,
            .confidence = "high",
            .event_identity = "fr:2026-001",
            .published_at = "2026-07-04",
            .published_epoch_ms = 2_000,
            .fetch_ms = 42,
            .http_status = 200,
        },
        .{
            .observed_at = "2026-07-04T00:00:00Z",
            .epoch_ms = 1_000,
            .source_id = "anthropic_news",
            .source_label = "Anthropic News",
            .source_kind = "feed_watch",
            .event = events.ev_baseline,
            .http_status = 304,
        },
    };
    try events.appendLog(io, a, log_path, &seeded, 10_000);

    // Seed a small state file through the real save path.
    const st = state.State{
        .federal_register_seen = @constCast(&[_][]const u8{ "2026-001", "2026-002" }),
        .keyword_hashes = @constCast(&[_]state.State.KeywordHash{
            .{ .id = "anthropic_news", .hash = "deadbeef" },
            .{ .id = "policy_page", .hash = "c0ffee" },
        }),
    };
    try state.saveState(&ctx, st);

    // Run the export into a fresh output directory.
    try exportParquet(&ctx, out_dir);

    // All three tables must exist and be well-framed Parquet.
    try expectParquetFile(io, a, out_dir ++ "/events.parquet");
    try expectParquetFile(io, a, out_dir ++ "/state_seen.parquet");
    try expectParquetFile(io, a, out_dir ++ "/state_keyword_hashes.parquet");
}

test "exportParquet tolerates absent inputs and still creates the output dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;

    // Point at paths that do not exist: readLog and loadState both error, and
    // export.zig catches those to log-and-skip rather than aborting the run.
    const state_path = ".test-fable-monitor-export-empty-state.jsonl.zst";
    const log_path = ".test-fable-monitor-export-empty-log.jsonl";
    const out_dir = ".test-fable-monitor-export-empty-out";

    defer {
        Io.Dir.cwd().deleteTree(io, out_dir) catch {};
        // The shared-lock acquisition on the missing log still touches a lock
        // sibling; clean it up defensively.
        Io.Dir.cwd().deleteFile(io, log_path ++ ".lock") catch {};
        Io.Dir.cwd().deleteFile(io, state_path ++ ".lock") catch {};
    }

    var ctx = Context{
        .io = io,
        .arena = a,
        .state_path = state_path,
        .log_path = log_path,
        .notify_cmd = null,
        .observed_at = "2026-07-04T00:00:00Z",
        .epoch_ms = 1_000,
    };

    // Must not error and must not crash with both inputs missing.
    try exportParquet(&ctx, out_dir);

    // The output directory is created up front, before any source is read.
    var dir = try Io.Dir.cwd().openDir(io, out_dir, .{});
    dir.close(io);

    // No table should have been emitted, since both sources were unavailable.
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, out_dir ++ "/events.parquet", .{}));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, out_dir ++ "/state_seen.parquet", .{}));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, out_dir ++ "/state_keyword_hashes.parquet", .{}));
}

test "row projects a known set of Parquet values into a fresh slice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const values = [_]parquet.Value{
        .{ .str = "2026-001" },
        .{ .int = 7 },
    };
    const projected = try row(a, &values);

    // A distinct allocation carrying identical values.
    try testing.expect(projected.ptr != &values);
    try testing.expectEqual(@as(usize, 2), projected.len);
    try testing.expectEqualStrings("2026-001", projected[0].str);
    try testing.expectEqual(@as(i64, 7), projected[1].int);
}
