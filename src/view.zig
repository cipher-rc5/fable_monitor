//! `fable-monitor log` / `fable-monitor view` — formatted readers for the
//! observation history.
//!
//! Decompresses the JSONL event log and prints it as an aligned, colorized
//! table, so you can read the data without `zstd -dc … | jq` or a Parquet
//! round-trip. Supports a few filters and a plain (tab-separated) mode for
//! piping into grep/awk.
//!
//!   fable-monitor log  [--source ID] [--event KIND] [--limit N]
//!                      [--since DATE] [--days N] [--desc|--asc] [--relevant]
//!                      [--width COLS] [--plain] [--color|--no-color]
//!
//! `--width` defaults to the terminal's column count (so long titles aren't
//! clipped); when stdout isn't a TTY it falls back to 100 columns.
//!
//! `view` is a dataview preset: the same reader with the window defaulted to
//! the last 90 days and the order defaulted to newest-first, for an at-a-glance
//! table of recent activity. Every flag still applies and overrides the preset.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const events = @import("events.zig");
const Event = events.Event;
const log = @import("context.zig").log;

/// Which preset the reader starts from. `log` shows the full history oldest
/// -first; `view` windows to the last 90 days and flips to newest-first.
pub const Mode = enum { log, view };

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
    since: ?[]const u8 = null, // inclusive lower bound on observed_at (ISO date/prefix)
    days: ?usize = null, // window width: keep events newer than now − days
    relevant: bool = false, // keep only high-signal events (relevant_document, changed)
    desc: bool = false, // newest-first when true
    limit: ?usize = null,
    width: ?usize = null, // null → auto (terminal width if stdout is a TTY, else 100)
    plain: bool = false,
    color: ?bool = null, // null → auto (on iff stdout is a TTY)
};

/// Entry point for the `log` / `view` subcommands. `args` is argv after the
/// subcommand; `now_secs` is the current instant (seconds since the epoch),
/// used to resolve `--days` into a cutoff. `mode` selects the starting preset.
pub fn run(io: Io, arena: Allocator, log_path: []const u8, args: []const [:0]const u8, mode: Mode, now_secs: i64) !void {
    // `view` is "the last quarter, newest-first"; `log` is the full history
    // oldest-first. Explicit flags below override either preset.
    var opts: Options = switch (mode) {
        .log => .{},
        .view => .{ .days = 90, .desc = true },
    };
    const usage = "Usage: " ++ "[--source ID] [--event KIND] [--since DATE] [--days N] [--relevant] [--desc|--asc] [--limit N] [--width COLS] [--plain] [--color|--no-color]";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--plain")) {
            opts.plain = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            opts.color = false;
        } else if (std.mem.eql(u8, a, "--color")) {
            opts.color = true;
        } else if (std.mem.eql(u8, a, "--relevant")) {
            opts.relevant = true;
        } else if (std.mem.eql(u8, a, "--desc")) {
            opts.desc = true;
        } else if (std.mem.eql(u8, a, "--asc")) {
            opts.desc = false;
        } else if (flagValue(args, &i, a, "--source")) |v| {
            opts.source = v;
        } else if (flagValue(args, &i, a, "--event")) |v| {
            opts.event = v;
        } else if (flagValue(args, &i, a, "--since")) |v| {
            opts.since = v;
        } else if (flagValue(args, &i, a, "--days")) |v| {
            opts.days = std.fmt.parseInt(usize, v, 10) catch {
                log("{s}: --days expects a number, got '{s}'", .{ @tagName(mode), v });
                return;
            };
        } else if (flagValue(args, &i, a, "--limit")) |v| {
            opts.limit = std.fmt.parseInt(usize, v, 10) catch {
                log("{s}: --limit expects a number, got '{s}'", .{ @tagName(mode), v });
                return;
            };
        } else if (flagValue(args, &i, a, "--width")) |v| {
            opts.width = std.fmt.parseInt(usize, v, 10) catch opts.width;
        } else {
            log("{s}: unknown option '{s}'. {s}", .{ @tagName(mode), a, usage });
            return;
        }
    }

    // Resolve the time window into a single ISO cutoff string. observed_at is
    // ISO-8601 UTC, so a lexicographic compare is also a chronological one; an
    // explicit `--since` always wins over the `--days` width.
    const cutoff: ?[]const u8 = if (opts.since) |s|
        s
    else if (opts.days) |d|
        events.isoUtc(arena, now_secs -| @as(i64, @intCast(d)) * 86_400) catch null
    else
        null;

    // Load + decompress + parse the log.
    const data = events.readLog(io, arena, log_path) catch {
        log("no observation log at {s} (run a poll first, or set FABLE_MONITOR_LOG)", .{log_path});
        return;
    };

    var rows: std.ArrayList(Event) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        const parsed = std.json.parseFromSlice(Event, arena, t, .{ .ignore_unknown_fields = true }) catch continue;
        const e = parsed.value;
        if (opts.source) |s| if (!std.mem.eql(u8, e.source_id, s)) continue;
        if (opts.event) |ev| if (!std.mem.eql(u8, e.event, ev)) continue;
        if (opts.relevant and !isRelevant(e.event)) continue;
        if (cutoff) |c| if (std.mem.order(u8, e.observed_at, c) == .lt) continue;
        try rows.append(arena, e);
    }

    // Normalize to chronological order (the log is append-ordered, but sorting
    // makes the window robust to any out-of-order lines), then window by limit.
    std.mem.sort(Event, rows.items, {}, lessByTime);

    // Keep the most recent `limit` rows (the tail of the ascending list).
    var shown = rows.items;
    if (opts.limit) |n| if (shown.len > n) {
        shown = shown[shown.len - n ..];
    };

    // Flip to newest-first if requested (the dataview default).
    if (opts.desc) std.mem.reverse(Event, shown);

    if (shown.len == 0) {
        log("no events to show ({s})", .{if (rows.items.len == 0) "log is empty" else "all filtered out"});
        return;
    }

    const use_color = opts.color orelse (Io.File.stdout().isTty(io) catch false);

    // Resolve table width: an explicit --width wins; otherwise size to the
    // terminal so long titles aren't clipped, falling back to 100 columns when
    // stdout isn't a TTY (piped/redirected) or the query fails. Reserve a
    // one-column right margin against the detected terminal width: a row that
    // fills the last column sets the terminal's pending-wrap bit and renders as
    // a broken/extra wrap (notably in Ghostty). An explicit --width is honored
    // verbatim — the caller owns that number.
    const width = opts.width orelse if (terminalWidth(io)) |w| w -| 1 else 100;

    var out: std.ArrayList(u8) = .empty;
    if (opts.plain) {
        try renderPlain(arena, &out, shown);
    } else {
        try renderTable(arena, &out, shown, width, use_color);
    }

    var buf: [8192]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(out.items);
    try fw.interface.flush();
}

/// High-signal events: a relevant Federal Register document, or a watched
/// keyword context that shifted. Used by `--relevant`.
fn isRelevant(ev: []const u8) bool {
    return std.mem.eql(u8, ev, events.ev_relevant_document) or
        std.mem.eql(u8, ev, events.ev_changed);
}

/// Ascending order by observed_at. Both operands are ISO-8601 UTC, so a byte
/// compare is a time compare.
fn lessByTime(_: void, a: Event, b: Event) bool {
    return std.mem.lessThan(u8, a.observed_at, b.observed_at);
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

/// Best-effort terminal column count for stdout, via the TIOCGWINSZ ioctl.
/// Returns null when stdout isn't a terminal (piped/redirected) or the query
/// fails — the caller then falls back to a fixed default width.
fn terminalWidth(io: Io) ?usize {
    const stdout = Io.File.stdout();
    if (!(stdout.isTty(io) catch false)) return null;
    var ws: std.posix.winsize = undefined;
    const fd = stdout.handle;
    const req = std.posix.T.IOCGWINSZ;
    // The ioctl signature differs by platform: Linux takes the argp as a usize
    // and returns an errno-encoded usize; libc systems (macOS) take a pointer
    // and return -1 on error.
    const ok = switch (builtin.os.tag) {
        .linux => @as(isize, @bitCast(std.os.linux.ioctl(fd, req, @intFromPtr(&ws)))) >= 0,
        else => std.posix.system.ioctl(fd, @intCast(req), &ws) == 0,
    };
    if (!ok or ws.col == 0) return null;
    return ws.col;
}

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

test "isRelevant only matches high-signal kinds" {
    try testing.expect(isRelevant(events.ev_relevant_document));
    try testing.expect(isRelevant(events.ev_changed));
    try testing.expect(!isRelevant(events.ev_new_document));
    try testing.expect(!isRelevant(events.ev_baseline));
}

test "lessByTime orders by ISO observed_at; sort+reverse gives newest-first" {
    var rows = [_]Event{
        .{ .observed_at = "2026-06-22T05:54:00Z" },
        .{ .observed_at = "2026-06-18T23:05:00Z" },
        .{ .observed_at = "2026-06-24T08:40:00Z" },
    };
    std.mem.sort(Event, &rows, {}, lessByTime);
    try testing.expectEqualStrings("2026-06-18T23:05:00Z", rows[0].observed_at);
    try testing.expectEqualStrings("2026-06-24T08:40:00Z", rows[2].observed_at);
    // The dataview default flips ascending → newest-first.
    std.mem.reverse(Event, &rows);
    try testing.expectEqualStrings("2026-06-24T08:40:00Z", rows[0].observed_at);
}

test "cutoff compare: ISO observed_at vs date-only --since is inclusive of that day" {
    // observed_at on the since date sorts >= the bare date prefix (kept).
    try testing.expect(std.mem.order(u8, "2026-06-20T00:00:00Z", "2026-06-20") != .lt);
    // The day before is dropped.
    try testing.expect(std.mem.order(u8, "2026-06-19T23:59:59Z", "2026-06-20") == .lt);
}
