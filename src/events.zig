//! The observation event model: one row of poll history, the event-kind tags,
//! UTC timestamp formatting, and appending a run's events to the history log.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zstd = @import("zstd.zig");
const log = @import("context.zig").log;

/// One row of the observation history. Appended to the NDJSON log as a poll
/// finds new documents or keyword shifts, and later projected into Parquet by
/// the `export` subcommand. Field names are the NDJSON/Parquet column names.
pub const Event = struct {
    observed_at: []const u8 = "", // ISO-8601 UTC, shared by all events in a run
    epoch_ms: i64 = 0, // same instant, milliseconds since the Unix epoch
    source_id: []const u8 = "",
    source_label: []const u8 = "",
    source_kind: []const u8 = "", // "federal_register" | "keyword_watch"
    event: []const u8 = "", // see EventKind below
    document_number: []const u8 = "",
    title: []const u8 = "",
    publication_date: []const u8 = "",
    url: []const u8 = "",
    detail: []const u8 = "", // free-form: keyword hash, byte counts, etc.
};

// Event kinds, kept as string literals so the log stays self-describing.
pub const ev_new_document = "new_document";
pub const ev_relevant_document = "relevant_document";
pub const ev_baseline = "baseline";
pub const ev_changed = "changed";

/// Format `epoch_secs` (seconds since the Unix epoch) as an ISO-8601 UTC string
/// like "2026-06-18T14:03:09Z". Pre-1970 instants clamp to the epoch.
pub fn isoUtc(arena: Allocator, epoch_secs: i64) ![]u8 {
    const secs: u64 = if (epoch_secs < 0) 0 else @intCast(epoch_secs);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(
        arena,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            yd.year,
            md.month.numeric(),
            @as(u32, md.day_index) + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        },
    );
}

/// Append this run's events to the compressed JSONL history log. Because the
/// file is a single zstd stream, "append" is a read-modify-write: decompress
/// the existing log, add this run's lines, recompress, and rewrite. The log
/// grows with events (not poll frequency), so the rewrite cost stays small.
/// No-op when the run found nothing new.
pub fn appendLog(io: Io, arena: Allocator, log_path: []const u8, events: []const Event) !void {
    if (events.len == 0) return;

    var buf: std.ArrayList(u8) = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(256 * 1024 * 1024)) catch null) |raw| {
        const existing = zstd.decompress(io, arena, raw) catch &.{};
        try buf.appendSlice(arena, existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') {
            try buf.append(arena, '\n');
        }
    }
    for (events) |ev| {
        const line = try std.json.Stringify.valueAlloc(arena, ev, .{});
        try buf.appendSlice(arena, line);
        try buf.append(arena, '\n');
    }

    const compressed = try zstd.compress(io, arena, buf.items);
    var file = try Io.Dir.cwd().createFile(io, log_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, compressed);
    log("appended {d} event(s) to {s} ({d} bytes compressed)", .{ events.len, log_path, compressed.len });
}
