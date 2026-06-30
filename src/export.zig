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
const Event = @import("events.zig").Event;
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

/// Read a whole file into the arena, or return null if it is absent/unreadable.
fn readFileMaybe(ctx: *Context, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(256 * 1024 * 1024)) catch null;
}

/// Build a one-row slice of Parquet values in the arena.
fn row(a: Allocator, values: []const parquet.Value) ![]const parquet.Value {
    return a.dupe(parquet.Value, values);
}

fn exportEvents(ctx: *Context, out_dir: []const u8) !void {
    const a = ctx.arena;
    const raw = readFileMaybe(ctx, ctx.log_path) orelse {
        log("no observation log at {s}; skipping events.parquet", .{ctx.log_path});
        return;
    };
    const data = try zstd.decompress(ctx.io, a, raw);

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
