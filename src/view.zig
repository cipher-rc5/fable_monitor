//! `fable-monitor log` — a formatted reader for the observation history.
//!
//! Decompresses the JSONL event log and prints it as an aligned, colorized
//! table, so you can read the data without `zstd -dc … | jq` or a Parquet
//! round-trip. Supports a few filters and a plain (tab-separated) mode for
//! piping into grep/awk.
//!
//!   fable-monitor log [--source ID] [--event KIND] [--limit N]
//!                     [--width COLS] [--plain] [--color|--no-color]

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zstd = @import("zstd.zig");
const events = @import("events.zig");
const Event = events.Event;
const log = @import("context.zig").log;

// ANSI styling. Emitted only when color is on; the codes are zero-width, so
// padding is computed on the visible text and the codes wrap it afterward.
const reset = "\x1b[0m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const red = "\x1b[31m";
const yellow = "\x1b[33m";
const cyan = "\x1b[36m";

const Options = struct {
    source: ?[]const u8 = null,
    event: ?[]const u8 = null,
    limit: ?usize = null,
    width: usize = 100,
    plain: bool = false,
    color: ?bool = null, // null → auto (on iff stdout is a TTY)
};

/// Entry point for the `log` subcommand. `args` is argv after the subcommand.
pub fn run(io: Io, arena: Allocator, log_path: []const u8, args: []const [:0]const u8) !void {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--plain")) {
            opts.plain = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            opts.color = false;
        } else if (std.mem.eql(u8, a, "--color")) {
            opts.color = true;
        } else if (flagValue(args, &i, a, "--source")) |v| {
            opts.source = v;
        } else if (flagValue(args, &i, a, "--event")) |v| {
            opts.event = v;
        } else if (flagValue(args, &i, a, "--limit")) |v| {
            opts.limit = std.fmt.parseInt(usize, v, 10) catch {
                log("log: --limit expects a number, got '{s}'", .{v});
                return;
            };
        } else if (flagValue(args, &i, a, "--width")) |v| {
            opts.width = std.fmt.parseInt(usize, v, 10) catch opts.width;
        } else {
            log("log: unknown option '{s}'. Usage: log [--source ID] [--event KIND] [--limit N] [--width COLS] [--plain] [--color|--no-color]", .{a});
            return;
        }
    }

    // Load + decompress + parse the log.
    const raw = Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(256 * 1024 * 1024)) catch {
        log("no observation log at {s} (run a poll first, or set FABLE_MONITOR_LOG)", .{log_path});
        return;
    };
    const data = try zstd.decompress(io, arena, raw);

    var rows: std.ArrayList(Event) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        const parsed = std.json.parseFromSlice(Event, arena, t, .{ .ignore_unknown_fields = true }) catch continue;
        const e = parsed.value;
        if (opts.source) |s| if (!std.mem.eql(u8, e.source_id, s)) continue;
        if (opts.event) |ev| if (!std.mem.eql(u8, e.event, ev)) continue;
        try rows.append(arena, e);
    }

    // Keep the most recent `limit` rows.
    var shown = rows.items;
    if (opts.limit) |n| if (shown.len > n) {
        shown = shown[shown.len - n ..];
    };

    if (shown.len == 0) {
        log("no events to show ({s})", .{if (rows.items.len == 0) "log is empty" else "all filtered out"});
        return;
    }

    const use_color = opts.color orelse (Io.File.stdout().isTty(io) catch false);

    var out: std.ArrayList(u8) = .empty;
    if (opts.plain) {
        try renderPlain(arena, &out, shown);
    } else {
        try renderTable(arena, &out, shown, opts.width, use_color);
    }

    var buf: [8192]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(out.items);
    try fw.interface.flush();
}

/// Match `--name value` or `--name=value`; advances `i` past a separated value.
fn flagValue(args: []const [:0]const u8, i: *usize, arg: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') {
        return arg[name.len + 1 ..];
    }
    if (std.mem.eql(u8, arg, name) and i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

// --- rendering --------------------------------------------------------------

/// "2026-06-18T14:03:09Z" → "2026-06-18 14:03" (best effort; passthrough if short).
fn timeShort(arena: Allocator, s: []const u8) []const u8 {
    if (s.len < 16) return s;
    const b = arena.dupe(u8, s[0..16]) catch return s;
    b[10] = ' ';
    return b;
}

fn ref(e: Event) []const u8 {
    return if (e.document_number.len > 0) e.document_number else "—";
}

/// The free-text column: document title, else the watched URL, else detail.
fn info(e: Event) []const u8 {
    if (e.title.len > 0) return e.title;
    if (e.url.len > 0) return e.url;
    return e.detail;
}

fn eventStyle(ev: []const u8) []const u8 {
    if (std.mem.eql(u8, ev, events.ev_relevant_document)) return bold ++ red;
    if (std.mem.eql(u8, ev, events.ev_changed)) return bold ++ yellow;
    if (std.mem.eql(u8, ev, events.ev_new_document)) return cyan;
    if (std.mem.eql(u8, ev, events.ev_baseline)) return dim;
    return "";
}

/// Codepoint count (used as a stand-in for display width; correct for ASCII
/// and accented Latin, approximate for wide CJK).
fn cpLen(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// First `max` codepoints of `s`, with a trailing "…" if it was truncated.
fn trunc(arena: Allocator, s: []const u8, max: usize) []const u8 {
    if (max == 0) return "";
    if (cpLen(s) <= max) return s;
    var it = (std.unicode.Utf8View.init(s) catch return s[0..@min(s.len, max)]).iterator();
    var count: usize = 0;
    var byte: usize = 0;
    while (count + 1 < max) : (count += 1) {
        const slice = it.nextCodepointSlice() orelse break;
        byte += slice.len;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{s[0..byte]}) catch s[0..byte];
}

fn pad(out: *std.ArrayList(u8), a: Allocator, s: []const u8, width: usize) !void {
    try out.appendSlice(a, s);
    var n = width -| cpLen(s);
    while (n > 0) : (n -= 1) try out.append(a, ' ');
}

const col_gap = "  ";

fn renderTable(a: Allocator, out: *std.ArrayList(u8), rows: []const Event, total_width: usize, color: bool) !void {
    // Fixed-ish columns; compute each from the data, capped, then give the
    // remaining width to the free-text "info" column.
    const time_w: usize = 16;
    var src_w: usize = cpLen("SOURCE");
    var evt_w: usize = cpLen("EVENT");
    var ref_w: usize = cpLen("REF");
    for (rows) |e| {
        src_w = @max(src_w, cpLen(e.source_id));
        evt_w = @max(evt_w, cpLen(e.event));
        ref_w = @max(ref_w, cpLen(ref(e)));
    }
    src_w = @min(src_w, 16);
    evt_w = @min(evt_w, 18);
    ref_w = @min(ref_w, 14);

    const fixed = time_w + src_w + evt_w + ref_w + col_gap.len * 4;
    const info_w: usize = if (total_width > fixed + 8) total_width - fixed else 24;

    // Header + rule.
    if (color) try out.appendSlice(a, bold);
    try pad(out, a, "TIME", time_w);
    try out.appendSlice(a, col_gap);
    try pad(out, a, "SOURCE", src_w);
    try out.appendSlice(a, col_gap);
    try pad(out, a, "EVENT", evt_w);
    try out.appendSlice(a, col_gap);
    try pad(out, a, "REF", ref_w);
    try out.appendSlice(a, col_gap);
    try out.appendSlice(a, "INFO");
    if (color) try out.appendSlice(a, reset);
    try out.append(a, '\n');

    var rule = total_width;
    while (rule > 0) : (rule -= 1) try out.appendSlice(a, "─");
    try out.append(a, '\n');

    for (rows) |e| {
        try pad(out, a, timeShort(a, e.observed_at), time_w);
        try out.appendSlice(a, col_gap);
        try pad(out, a, trunc(a, e.source_id, src_w), src_w);
        try out.appendSlice(a, col_gap);
        // event cell: pad on the visible text, then wrap in color codes.
        const style = eventStyle(e.event);
        if (color and style.len > 0) try out.appendSlice(a, style);
        try pad(out, a, trunc(a, e.event, evt_w), evt_w);
        if (color and style.len > 0) try out.appendSlice(a, reset);
        try out.appendSlice(a, col_gap);
        try pad(out, a, trunc(a, ref(e), ref_w), ref_w);
        try out.appendSlice(a, col_gap);
        try out.appendSlice(a, trunc(a, info(e), info_w));
        try out.append(a, '\n');
    }

    try out.appendSlice(a, try std.fmt.allocPrint(a, "\n{d} event(s)\n", .{rows.len}));
}

/// Tab-separated, untruncated, no color — for piping into grep/awk.
fn renderPlain(a: Allocator, out: *std.ArrayList(u8), rows: []const Event) !void {
    try out.appendSlice(a, "observed_at\tsource_id\tsource_kind\tevent\tdocument_number\tpublication_date\turl\ttitle\tdetail\n");
    for (rows) |e| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            e.observed_at,      e.source_id, e.source_kind, e.event,  e.document_number,
            e.publication_date, e.url,       e.title,       e.detail,
        }));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "cpLen counts codepoints, not bytes" {
    try testing.expectEqual(@as(usize, 5), cpLen("fable"));
    try testing.expectEqual(@as(usize, 4), cpLen("café")); // é is 2 bytes
}

test "trunc keeps codepoint boundaries and adds an ellipsis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("fable", trunc(a, "fable", 10));
    try testing.expectEqualStrings("fa…", trunc(a, "fable", 3));
    // Truncation must not split the multibyte é.
    const t = trunc(a, "café", 3);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
}

test "flagValue handles both --name value and --name=value" {
    const argv = [_][:0]const u8{ "--source", "fr_bis", "--event=changed" };
    var i: usize = 0;
    try testing.expectEqualStrings("fr_bis", flagValue(&argv, &i, argv[0], "--source").?);
    try testing.expectEqual(@as(usize, 1), i);
    i = 2;
    try testing.expectEqualStrings("changed", flagValue(&argv, &i, argv[2], "--event").?);
}

test "timeShort trims to minute precision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("2026-06-18 14:03", timeShort(arena.allocator(), "2026-06-18T14:03:09Z"));
}
