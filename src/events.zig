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
///
/// Fields added after v1 (`tier`, `confidence`, `event_identity`,
/// `published_at`, `published_epoch_ms`, `fetch_ms`, `http_status`) default to
/// empty/zero, so logs written by older builds parse unchanged and older
/// readers ignore the extra columns.
pub const Event = struct {
    observed_at: []const u8 = "", // ISO-8601 UTC, shared by all events in a run
    epoch_ms: i64 = 0, // same instant, milliseconds since the Unix epoch
    source_id: []const u8 = "",
    source_label: []const u8 = "",
    source_kind: []const u8 = "", // SourceKind tag name
    event: []const u8 = "", // see the ev_* kinds below
    document_number: []const u8 = "",
    title: []const u8 = "",
    publication_date: []const u8 = "",
    url: []const u8 = "",
    detail: []const u8 = "", // free-form: keyword hash, byte counts, etc.

    // --- v2 additions (tiering, latency backtest, per-run metrics) ---------
    tier: u8 = 0, // 1/2/3; 0 = unset (pre-v2 rows)
    confidence: []const u8 = "", // "high" | "advisory" | ""
    event_identity: []const u8 = "", // normalized identity for cross-source dedup
    published_at: []const u8 = "", // source publication timestamp, if known
    published_epoch_ms: i64 = 0, // same instant in epoch ms (0 = unknown)
    fetch_ms: i64 = 0, // per-source fetch latency for metric rows
    http_status: i64 = 0, // HTTP status for metric rows (304 = not modified)
};

// Event kinds, kept as string literals so the log stays self-describing.
pub const ev_new_document = "new_document";
pub const ev_relevant_document = "relevant_document";
pub const ev_baseline = "baseline";
pub const ev_changed = "changed";
// v2 kinds.
pub const ev_restoration = "restoration"; // decisive tier-1 trip (model present / statement)
pub const ev_advisory = "advisory"; // lower-confidence tier-2/3 change
pub const ev_fetch = "fetch"; // per-source fetch metric (latency/status)
pub const ev_market = "market"; // recorded market state / movement
pub const ev_heartbeat = "heartbeat"; // dead-man's-switch ping result

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

/// Parse a source publication timestamp into epoch milliseconds, for the
/// latency backtest (publication-to-detection delta). Handles the two forms our
/// sources emit: a plain date "YYYY-MM-DD" and an ISO-8601 instant
/// "YYYY-MM-DDTHH:MM:SSZ". Returns null on anything else (e.g. RFC-822 pubDate),
/// so the caller records 0 = unknown rather than a wrong value.
pub fn epochMsFromIso(s: []const u8) ?i64 {
    if (s.len < 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    if (s.len >= 19 and (s[10] == 'T' or s[10] == ' ')) {
        hh = std.fmt.parseInt(i64, s[11..13], 10) catch 0;
        mm = std.fmt.parseInt(i64, s[14..16], 10) catch 0;
        ss = std.fmt.parseInt(i64, s[17..19], 10) catch 0;
    }
    const days = daysFromCivil(year, month, day);
    const secs = days * 86400 + hh * 3600 + mm * 60 + ss;
    return secs * 1000;
}

/// Days since the Unix epoch for a proleptic-Gregorian date (Howard Hinnant's
/// algorithm). Valid for the date range this tool sees.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Write `data` to `path` atomically: stage it in a uniquely named temp file
/// in the same directory (a suffix of the target path, so the rename never
/// crosses filesystems), then rename() over the target. A crash mid-write can
/// therefore never leave a torn file — readers see the old contents or the new
/// contents, whole. Shared by the state, event-sink, and log writers.
pub fn writeFileAtomic(io: Io, arena: Allocator, path: []const u8, data: []const u8) !void {
    // The random component keeps concurrent writers from colliding on the
    // staging name (the flock serializes ours, but stay safe against strays).
    var rnd: [8]u8 = undefined;
    Io.random(io, &rnd);
    const suffix = std.mem.readInt(u64, &rnd, .little);
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ path, suffix });
    {
        var file = try Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, data);
    }
    Io.Dir.cwd().rename(tmp_path, .cwd(), path, io) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };
}

/// Append this run's events to the compressed JSONL history log as one
/// independent zstd frame per run. zstd decodes concatenated frames as a
/// single stream (proven by a test below), so readers (`view`, `export`)
/// decompress the whole file unchanged, while the append never has to
/// decompress-recompress history. The rewrite copies the existing *raw* bytes
/// plus the new frame through a temp file and renames it into place, so a
/// crash mid-write cannot tear the log. When the existing log cannot be read
/// at all we refuse to rewrite it — log loudly and append the frame in place
/// instead, so unreadable history is never silently truncated. No-op when the
/// run found nothing new.
pub fn appendLog(io: Io, arena: Allocator, log_path: []const u8, events: []const Event) !void {
    if (events.len == 0) return;

    var buf: std.ArrayList(u8) = .empty;
    for (events) |ev| {
        const line = try std.json.Stringify.valueAlloc(arena, ev, .{});
        try buf.appendSlice(arena, line);
        try buf.append(arena, '\n');
    }
    const frame = try zstd.compress(io, arena, buf.items);

    const existing: ?[]u8 = Io.Dir.cwd().readFileAlloc(io, log_path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            // The log exists but cannot be read back (permissions, I/O, or
            // memory). Never rewrite what we could not read: append-only.
            log("error: cannot read {s} ({s}); appending frame without rewrite", .{ log_path, @errorName(err) });
            try appendRaw(io, log_path, frame);
            log("appended {d} event(s) to {s} ({d} bytes compressed)", .{ events.len, log_path, frame.len });
            return;
        },
    };
    const combined = if (existing) |raw| try std.mem.concat(arena, u8, &.{ raw, frame }) else frame;
    try writeFileAtomic(io, arena, log_path, combined);
    log("appended {d} event(s) to {s} ({d} bytes compressed)", .{ events.len, log_path, frame.len });
}

/// Append `bytes` at the current end of an existing file, in place. The
/// fallback for `appendLog` when the log exists but cannot be read for the
/// atomic copy-and-rename path.
fn appendRaw(io: Io, path: []const u8, bytes: []const u8) !void {
    var file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);
    const end = try file.length(io);
    try file.writePositionalAll(io, bytes, end);
}

const testing = std.testing;

test "concatenated zstd frames decompress as one stream (appendLog's format)" {
    // appendLog writes one independent frame per run; `zstd -d` (which
    // zstd.decompress shells to) must decode the concatenation as one stream.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;

    const f1 = try zstd.compress(io, a, "{\"event\":\"one\"}\n");
    const f2 = try zstd.compress(io, a, "{\"event\":\"two\"}\n");
    const cat = try std.mem.concat(a, u8, &.{ f1, f2 });
    const out = try zstd.decompress(io, a, cat);
    try testing.expectEqualStrings("{\"event\":\"one\"}\n{\"event\":\"two\"}\n", out);
}

test "writeFileAtomic creates and then replaces the target whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;

    const path = ".test-fable-monitor-atomic.tmp-target";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeFileAtomic(io, a, path, "first contents");
    try writeFileAtomic(io, a, path, "second");
    const got = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    try testing.expectEqualStrings("second", got);
}

test "epochMsFromIso parses dates and instants, round-trips through isoUtc" {
    // 1970-01-01 is epoch 0.
    try testing.expectEqual(@as(i64, 0), epochMsFromIso("1970-01-01").?);
    // A known instant: 2026-06-28T00:00:00Z.
    const ms = epochMsFromIso("2026-06-28T12:34:56Z").?;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const iso = try isoUtc(arena_state.allocator(), @divFloor(ms, 1000));
    try testing.expectEqualStrings("2026-06-28T12:34:56Z", iso);
    // Plain date floors to midnight UTC.
    const day = epochMsFromIso("2026-06-28").?;
    const iso_day = try isoUtc(arena_state.allocator(), @divFloor(day, 1000));
    try testing.expectEqualStrings("2026-06-28T00:00:00Z", iso_day);
    // Unparseable forms return null.
    try testing.expect(epochMsFromIso("Mon, 01 Jan 2026 00:00:00 GMT") == null);
    try testing.expect(epochMsFromIso("") == null);
}
