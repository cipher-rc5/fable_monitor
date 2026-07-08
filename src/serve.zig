//! `fable-monitor serve` — a tiny read-only HTTP dashboard over the observation
//! log and current state. The backend is otherwise a poll-once CLI; this
//! subcommand is the only long-running mode. It binds 127.0.0.1 only and never
//! mutates anything, so it is safe to leave running alongside the scheduled
//! poller, which owns the same files.
//!
//! The page shell (Tailwind v4 + htmx, both from a CDN) is served at `/`; htmx
//! polls the `/ui/*` fragment endpoints on an interval and swaps the returned
//! HTML in place. Each request renders from a fresh arena so a long-lived server
//! does not accumulate memory. Parsed log/state data is cached across requests
//! in a `Cache` keyed by file mtime, so the frequent htmx polls only spawn zstd
//! and re-parse history when the poller actually rewrote a file.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const http = std.http;
const Allocator = std.mem.Allocator;

const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const log = ctx_mod.log;
const events = @import("events.zig");
const Event = events.Event;
const state_mod = @import("state.zig");
const config = @import("config.zig");
const zstd = @import("zstd.zig");
const fetch = @import("fetch.zig");

pub const default_port: u16 = 8787;

/// Bind 127.0.0.1:port and serve until interrupted. `load_opts` mirrors the
/// poll-time source resolution so the sources panel shows the same set the
/// poller would act on.
pub fn run(ctx: *Context, load_opts: config.LoadOptions, port: u16) !void {
    var addr = net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var server = addr.listen(ctx.io, .{ .reuse_address = true }) catch |e| {
        log("serve: cannot bind 127.0.0.1:{d}: {s}", .{ port, @errorName(e) });
        return e;
    };
    log("UI listening on http://127.0.0.1:{d}  (Ctrl-C to stop)", .{port});

    // Server-lifetime cache of parsed dashboard data; requests are handled one
    // at a time, so no locking is needed.
    var cache = Cache.init(std.heap.page_allocator);
    defer cache.deinit();

    while (true) {
        const stream = server.accept(ctx.io) catch |e| {
            log("serve: accept failed: {s}", .{@errorName(e)});
            continue;
        };
        handleConn(ctx, load_opts, &cache, stream) catch |e| {
            log("serve: connection error: {s}", .{@errorName(e)});
        };
    }
}

/// One request per connection (Connection: close): simplest robust model for a
/// localhost dashboard, where htmx opens a fresh connection per poll anyway.
fn handleConn(ctx: *Context, load_opts: config.LoadOptions, cache: *Cache, stream: net.Stream) !void {
    defer stream.close(ctx.io);

    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(ctx.io, &rbuf);
    var sw = stream.writer(ctx.io, &wbuf);
    var hs = http.Server.init(&sr.interface, &sw.interface);

    var req = hs.receiveHead() catch return; // client closed or malformed head
    const target = req.head.target;

    var ra = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer ra.deinit();
    const a = ra.allocator();

    // Per-request context: share io and resolved paths, but render from the
    // request arena so memory is reclaimed when the connection closes.
    var rctx = ctx.*;
    rctx.arena = a;
    rctx.events = .empty;

    const path = pathOf(target);

    var body: ?[]const u8 = null;
    var ctype: []const u8 = "text/html; charset=utf-8";
    if (eql(path, "/")) {
        body = shell;
    } else if (eql(path, "/ui/status")) {
        body = renderStatus(&rctx, load_opts, cache) catch errFrag(a);
    } else if (eql(path, "/ui/sources")) {
        body = renderSources(&rctx, load_opts, cache) catch errFrag(a);
    } else if (eql(path, "/ui/events")) {
        body = renderEvents(&rctx, cache, target) catch errFrag(a);
    } else if (eql(path, "/ui/alerts")) {
        body = renderAlerts(&rctx, cache) catch errFrag(a);
    } else if (eql(path, "/ui/search-index")) {
        body = renderSearchIndex(&rctx, cache) catch "[]";
        ctype = "application/json; charset=utf-8";
    } else if (eql(path, "/reader")) {
        body = renderReader(&rctx, cache, target) catch readerError(a, "reader error — check the server log");
    } else if (eql(path, "/healthz")) {
        body = "ok";
        ctype = "text/plain; charset=utf-8";
    }

    if (body) |html| {
        try req.respond(html, .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = ctype }},
        });
    } else {
        try req.respond("<p class=\"text-rose-400\">404 — not found</p>", .{
            .status = .not_found,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }
}

// --- fragment renderers -----------------------------------------------------

fn renderStatus(ctx: *Context, load_opts: config.LoadOptions, cache: *Cache) ![]const u8 {
    const a = ctx.arena;
    const rows = cache.events(ctx);
    const st = cache.state(ctx);
    const cfg = config.load(ctx, load_opts);

    var last_obs: []const u8 = "—";
    var max_ms: i64 = 0;
    for (rows) |e| {
        if (e.epoch_ms > max_ms) {
            max_ms = e.epoch_ms;
            if (e.observed_at.len > 0) last_obs = e.observed_at;
        }
    }

    var active_alerts: usize = 0;
    for (st.alerts) |al| {
        if (!al.acknowledged) active_alerts += 1;
    }

    const alert_accent = if (active_alerts > 0) "text-rose-400" else "text-emerald-400";

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "<div class=\"grid grid-cols-2 md:grid-cols-4 gap-3\">");
    try card(a, &out, "Sources", try std.fmt.allocPrint(a, "{d}", .{cfg.sources.len}), "text-sky-400");
    try card(a, &out, "Events logged", try std.fmt.allocPrint(a, "{d}", .{rows.len}), "text-sky-400");
    try card(a, &out, "Active alerts", try std.fmt.allocPrint(a, "{d}", .{active_alerts}), alert_accent);
    try card(a, &out, "Last observed", esc(a, last_obs), "text-slate-200");
    try out.appendSlice(a, "</div>");
    return out.items;
}

fn renderSources(ctx: *Context, load_opts: config.LoadOptions, cache: *Cache) ![]const u8 {
    const a = ctx.arena;
    const cfg = config.load(ctx, load_opts);
    const st = cache.state(ctx);

    var out: std.ArrayList(u8) = .empty;
    try tableHead(a, &out, &.{ "Tier", "ID", "Source", "Kind", "Poll", "Last success", "Last change" });
    for (cfg.sources) |s| {
        const status = st.statusFor(s.id);
        const last_ok = if (status) |ss| try msToIso(ctx, ss.last_success_ms) else "—";
        const last_chg = if (status) |ss| try msToIso(ctx, ss.last_change_ms) else "—";
        try out.appendSlice(a, "<tr class=\"border-t border-slate-800 hover:bg-slate-800/40\">");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "<td class=\"px-3 py-2\">{s}</td>", .{tierBadge(s.tier.int())}));
        try td(a, &out, esc(a, s.id), "font-mono text-xs text-slate-400");
        try td(a, &out, esc(a, s.label), "text-slate-200");
        try td(a, &out, esc(a, s.kind.logName()), "text-slate-400");
        try td(a, &out, @tagName(s.poll), "text-slate-400");
        try td(a, &out, esc(a, last_ok), "text-slate-400 text-xs");
        try td(a, &out, esc(a, last_chg), "text-slate-400 text-xs");
        try out.appendSlice(a, "</tr>");
    }
    try out.appendSlice(a, "</tbody></table>");
    return out.items;
}

fn renderEvents(ctx: *Context, cache: *Cache, target: []const u8) ![]const u8 {
    const a = ctx.arena;
    const limit = queryUint(target, "limit") orelse 25;
    const rows = cache.events(ctx); // ascending by time
    const start = if (rows.len > limit) rows.len - limit else 0;

    var out: std.ArrayList(u8) = .empty;
    try tableHead(a, &out, &.{ "Observed", "Tier", "Source", "Event", "Detail" });
    // Newest first.
    var i: usize = rows.len;
    while (i > start) {
        i -= 1;
        const e = rows[i];
        const detail = if (e.title.len > 0) e.title else if (e.document_number.len > 0) e.document_number else e.detail;
        try out.appendSlice(a, "<tr class=\"border-t border-slate-800 hover:bg-slate-800/40\">");
        try td(a, &out, esc(a, e.observed_at), "text-slate-400 text-xs whitespace-nowrap");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "<td class=\"px-3 py-2\">{s}</td>", .{tierBadge(e.tier)}));
        try td(a, &out, esc(a, e.source_id), "font-mono text-xs text-slate-400");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "<td class=\"px-3 py-2\">{s}</td>", .{eventBadge(a, e.event)}));
        try out.appendSlice(a, try std.fmt.allocPrint(a, "<td class=\"px-3 py-2 text-slate-200\">{s}</td>", .{detailCell(a, esc(a, detail), e.url)}));
        try out.appendSlice(a, "</tr>");
    }
    if (rows.len == 0) {
        try out.appendSlice(a, "<tr><td colspan=\"5\" class=\"px-3 py-6 text-center text-slate-500\">No events logged yet — run a poll.</td></tr>");
    }
    try out.appendSlice(a, "</tbody></table>");
    return out.items;
}

fn renderAlerts(ctx: *Context, cache: *Cache) ![]const u8 {
    const a = ctx.arena;
    const st = cache.state(ctx);

    var out: std.ArrayList(u8) = .empty;
    try tableHead(a, &out, &.{ "Tier", "Kind", "Title", "First alerted", "Status" });
    var shown: usize = 0;
    for (st.alerts) |al| {
        shown += 1;
        const badge = if (al.acknowledged)
            "<span class=\"rounded bg-slate-700 px-2 py-0.5 text-xs text-slate-300\">acknowledged</span>"
        else if (al.escalated)
            "<span class=\"rounded bg-rose-500/20 px-2 py-0.5 text-xs text-rose-300\">escalated</span>"
        else
            "<span class=\"rounded bg-amber-500/20 px-2 py-0.5 text-xs text-amber-300\">active</span>";
        try out.appendSlice(a, "<tr class=\"border-t border-slate-800 hover:bg-slate-800/40\">");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "<td class=\"px-3 py-2\">{s}</td>", .{tierBadge(al.tier)}));
        try td(a, &out, esc(a, al.ev_kind), "text-slate-400");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "<td class=\"px-3 py-2 text-slate-200\">{s}</td>", .{detailCell(a, esc(a, al.title), al.url)}));
        try td(a, &out, esc(a, try msToIso(ctx, al.epoch_ms)), "text-slate-400 text-xs");
        try out.appendSlice(a, try std.fmt.allocPrint(a, "<td class=\"px-3 py-2\">{s}</td>", .{badge}));
        try out.appendSlice(a, "</tr>");
    }
    if (shown == 0) {
        try out.appendSlice(a, "<tr><td colspan=\"5\" class=\"px-3 py-6 text-center text-emerald-400\">No alerts — access status nominal.</td></tr>");
    }
    try out.appendSlice(a, "</tbody></table>");
    return out.items;
}

// --- search index -----------------------------------------------------------

/// The search corpus: every observation event plus every alert, emitted as a
/// flat JSON array the browser indexes with Orama. Rendered from the same arena
/// as the fragments, so it is reclaimed when the connection closes.
fn renderSearchIndex(ctx: *Context, cache: *Cache) ![]const u8 {
    const a = ctx.arena;
    const rows = cache.events(ctx);
    const st = cache.state(ctx);

    // The poller re-logs the same items every tick, so the raw log is dominated
    // by duplicates. Collapse to one entry per (title,url), keeping the newest
    // occurrence, so the browser indexes a small, clean corpus.
    var seen = std.StringHashMap(void).init(a);

    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    var first = true;

    // Events, newest first (matches the recent_events table ordering).
    var i: usize = rows.len;
    while (i > 0) {
        i -= 1;
        const e = rows[i];
        const title = if (e.title.len > 0) e.title else if (e.document_number.len > 0) e.document_number else e.detail;
        if (title.len == 0 and e.url.len == 0) continue;
        const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ title, e.url });
        if (seen.contains(key)) continue;
        try seen.put(key, {});
        if (!first) try out.append(a, ',');
        first = false;
        const src = if (e.source_label.len > 0) e.source_label else e.source_id;
        try out.appendSlice(a, try std.fmt.allocPrint(
            a,
            "{{\"t\":\"event\",\"title\":{s},\"source\":{s},\"tier\":{d},\"kind\":{s},\"event\":{s},\"url\":{s},\"when\":{s},\"ts\":{d},\"detail\":{s}}}",
            .{ jsonStr(a, title), jsonStr(a, src), e.tier, jsonStr(a, e.event), jsonStr(a, e.event), jsonStr(a, e.url), jsonStr(a, e.observed_at), e.epoch_ms, jsonStr(a, e.detail) },
        ));
    }

    // Alerts. Skipped when an identical (title,url) already appeared as an event
    // (the event entry opens the same source), so results stay deduplicated.
    for (st.alerts) |al| {
        if (al.title.len == 0 and al.url.len == 0) continue;
        const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ al.title, al.url });
        if (seen.contains(key)) continue;
        try seen.put(key, {});
        if (!first) try out.append(a, ',');
        first = false;
        const status = if (al.acknowledged) "acknowledged" else if (al.escalated) "escalated" else "active";
        const when = try msToIso(ctx, al.epoch_ms);
        try out.appendSlice(a, try std.fmt.allocPrint(
            a,
            "{{\"t\":\"alert\",\"title\":{s},\"source\":{s},\"tier\":{d},\"kind\":\"alert\",\"event\":{s},\"url\":{s},\"when\":{s},\"ts\":{d},\"detail\":{s}}}",
            .{ jsonStr(a, al.title), jsonStr(a, al.ev_kind), al.tier, jsonStr(a, status), jsonStr(a, al.url), jsonStr(a, when), al.epoch_ms, jsonStr(a, status) },
        ));
    }

    try out.append(a, ']');
    return out.items;
}

/// Quote and escape a string as a JSON string literal (including surrounding
/// double quotes). Control characters below 0x20 are emitted as \uXXXX.
fn jsonStr(a: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '"') catch {};
    for (s) |c| switch (c) {
        '"' => out.appendSlice(a, "\\\"") catch {},
        '\\' => out.appendSlice(a, "\\\\") catch {},
        '\n' => out.appendSlice(a, "\\n") catch {},
        '\r' => out.appendSlice(a, "\\r") catch {},
        '\t' => out.appendSlice(a, "\\t") catch {},
        else => if (c < 0x20) {
            out.appendSlice(a, std.fmt.allocPrint(a, "\\u{x:0>4}", .{c}) catch "") catch {};
        } else {
            out.append(a, c) catch {};
        },
    };
    out.append(a, '"') catch {};
    return out.items;
}

// --- parsed-data cache --------------------------------------------------------

/// Parsed dashboard data cached across requests, keyed by file mtime. The htmx
/// fragments poll every few seconds; without this every poll would spawn zstd
/// and re-parse the full history. The cache owns its memory via dedicated
/// arenas (one per file, reset only when that file's mtime moves), so slices it
/// hands out stay valid for the whole request that borrowed them — never
/// allocate cached data from a per-request arena.
const Cache = struct {
    events_arena: std.heap.ArenaAllocator,
    events_mtime: i96 = mtime_unset,
    events_items: []Event = &.{},

    state_arena: std.heap.ArenaAllocator,
    state_mtime: i96 = mtime_unset,
    state_val: state_mod.State = .{},

    /// Initial "never loaded" marker; distinct from `mtime_missing` so the
    /// first request always loads, even when the file does not exist yet.
    const mtime_unset: i96 = std.math.minInt(i96);
    /// Marker for "stat failed": lets a file that appears later be picked up.
    const mtime_missing: i96 = std.math.minInt(i96) + 1;

    fn init(gpa: Allocator) Cache {
        return .{
            .events_arena = std.heap.ArenaAllocator.init(gpa),
            .state_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    fn deinit(self: *Cache) void {
        self.events_arena.deinit();
        self.state_arena.deinit();
    }

    /// The observation log, parsed and sorted ascending by time. Re-reads only
    /// when the log file's mtime changed since the cached parse.
    fn events(self: *Cache, ctx: *Context) []Event {
        const mt = fileMtime(ctx.io, ctx.log_path);
        if (self.cachedEventsFor(mt)) |cached| return cached;
        // Scratch (compressed + decompressed bytes) goes in the request arena;
        // `refreshEvents` copies what the cache keeps into its own arena.
        const raw = Io.Dir.cwd().readFileAlloc(ctx.io, ctx.log_path, ctx.arena, .limited(256 * 1024 * 1024)) catch return &.{};
        const data = zstd.decompress(ctx.io, ctx.arena, raw) catch return &.{};
        return self.refreshEvents(mt, data);
    }

    /// The cached parse if it was built from a file with mtime `mt`, else null.
    fn cachedEventsFor(self: *Cache, mt: i96) ?[]Event {
        return if (mt == self.events_mtime) self.events_items else null;
    }

    /// Drop the previous parse and rebuild from `ndjson`, recording `mt` as
    /// the mtime the parse corresponds to. `.alloc_always` in `parseEventLog`
    /// guarantees no cached string borrows from `ndjson`.
    fn refreshEvents(self: *Cache, mt: i96, ndjson: []const u8) []Event {
        _ = self.events_arena.reset(.retain_capacity);
        self.events_items = parseEventLog(self.events_arena.allocator(), ndjson) catch &.{};
        self.events_mtime = mt;
        return self.events_items;
    }

    /// The saved state, re-read only when the state file's mtime changed.
    /// Loaded through a Context clone pointing at the cache's arena so the
    /// decompressed bytes the parsed State borrows from are cache-owned.
    fn state(self: *Cache, ctx: *Context) state_mod.State {
        const mt = fileMtime(ctx.io, ctx.state_path);
        if (mt == self.state_mtime) return self.state_val;
        _ = self.state_arena.reset(.retain_capacity);
        var cctx = ctx.*;
        cctx.arena = self.state_arena.allocator();
        self.state_val = state_mod.loadState(&cctx) catch state_mod.State{};
        self.state_mtime = mt;
        return self.state_val;
    }
};

/// Modification time of `path` in nanoseconds, or `Cache.mtime_missing` when
/// it cannot be stat'ed (missing file, permissions).
fn fileMtime(io: Io, path: []const u8) i96 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return Cache.mtime_missing;
    return st.mtime.nanoseconds;
}

/// Parse the decompressed NDJSON log into events sorted ascending by time.
/// `.alloc_always` copies every string into `arena`, so the result may outlive
/// the buffer it was parsed from.
fn parseEventLog(arena: Allocator, data: []const u8) ![]Event {
    var list: std.ArrayList(Event) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        const parsed = std.json.parseFromSlice(Event, arena, t, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        try list.append(arena, parsed.value);
    }
    std.mem.sort(Event, list.items, {}, lessByMs);
    return list.items;
}

// --- data + html helpers ----------------------------------------------------

fn lessByMs(_: void, x: Event, y: Event) bool {
    return x.epoch_ms < y.epoch_ms;
}

fn msToIso(ctx: *Context, ms: i64) ![]const u8 {
    if (ms <= 0) return "—";
    return events.isoUtc(ctx.arena, @divTrunc(ms, 1000));
}

fn card(a: Allocator, out: *std.ArrayList(u8), label: []const u8, value: []const u8, accent: []const u8) !void {
    try out.appendSlice(a, try std.fmt.allocPrint(a,
        \\<div class="rounded-lg border border-slate-800 bg-slate-900/60 p-4">
        \\<div class="text-xs uppercase tracking-wide text-slate-500">{s}</div>
        \\<div class="mt-1 text-2xl font-semibold {s}">{s}</div></div>
    , .{ esc(a, label), accent, value }));
}

fn tableHead(a: Allocator, out: *std.ArrayList(u8), headers: []const []const u8) !void {
    try out.appendSlice(a, "<table class=\"w-full text-left text-sm\"><thead><tr class=\"text-xs uppercase tracking-wide text-slate-500\">");
    for (headers) |h| {
        try out.appendSlice(a, "<th class=\"px-3 py-2 font-medium\">");
        try out.appendSlice(a, h);
        try out.appendSlice(a, "</th>");
    }
    try out.appendSlice(a, "</tr></thead><tbody>");
}

fn td(a: Allocator, out: *std.ArrayList(u8), inner: []const u8, classes: []const u8) !void {
    try out.appendSlice(a, try std.fmt.allocPrint(a, "<td class=\"px-3 py-2 {s}\">{s}</td>", .{ classes, inner }));
}

fn detailCell(a: Allocator, text: []const u8, url: []const u8) []const u8 {
    if (url.len == 0) return text;
    // Only http(s) URLs can be opened in-app; anything else (opaque aggregator
    // tokens, javascript:/data:/file:, …) is rendered as escaped plain text so a
    // hostile URL in the log can never become a live link.
    if (!urlSchemeAllowed(url)) {
        return std.fmt.allocPrint(a, "{s} <span class=\"text-slate-500 text-xs\">{s}</span>", .{ text, esc(a, url) }) catch text;
    }
    const u = esc(a, url);
    return std.fmt.allocPrint(a,
        "<a href=\"{s}\" data-reader-url=\"{s}\" data-reader-label=\"{s}\" class=\"reader-link text-sky-400 hover:underline\">{s}</a>" ++
            " <a href=\"{s}\" target=\"_blank\" rel=\"noreferrer\" class=\"reader-ext text-slate-500\" title=\"open externally\">↗</a>",
        .{ u, u, text, text, u },
    ) catch text;
}

/// Anchor-href allowlist: absolute http/https only, scheme case-insensitive.
fn urlSchemeAllowed(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or
        std.ascii.startsWithIgnoreCase(url, "https://");
}

fn tierBadge(tier: u8) []const u8 {
    return switch (tier) {
        1 => "<span class=\"rounded bg-rose-500/20 px-2 py-0.5 text-xs font-semibold text-rose-300\">T1</span>",
        2 => "<span class=\"rounded bg-amber-500/20 px-2 py-0.5 text-xs font-semibold text-amber-300\">T2</span>",
        3 => "<span class=\"rounded bg-sky-500/20 px-2 py-0.5 text-xs font-semibold text-sky-300\">T3</span>",
        else => "<span class=\"rounded bg-slate-700 px-2 py-0.5 text-xs text-slate-400\">—</span>",
    };
}

fn eventBadge(a: Allocator, kind: []const u8) []const u8 {
    if (eql(kind, events.ev_restoration))
        return "<span class=\"rounded bg-emerald-500/20 px-2 py-0.5 text-xs font-semibold text-emerald-300\">restoration</span>";
    if (eql(kind, events.ev_relevant_document))
        return "<span class=\"rounded bg-amber-500/20 px-2 py-0.5 text-xs text-amber-300\">relevant</span>";
    if (eql(kind, events.ev_advisory))
        return "<span class=\"rounded bg-sky-500/20 px-2 py-0.5 text-xs text-sky-300\">advisory</span>";
    if (eql(kind, events.ev_baseline))
        return "<span class=\"rounded bg-slate-700 px-2 py-0.5 text-xs text-slate-400\">baseline</span>";
    return std.fmt.allocPrint(a, "<span class=\"text-slate-400 text-xs\">{s}</span>", .{esc(a, kind)}) catch kind;
}

fn esc(a: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => out.appendSlice(a, "&amp;") catch {},
        '<' => out.appendSlice(a, "&lt;") catch {},
        '>' => out.appendSlice(a, "&gt;") catch {},
        '"' => out.appendSlice(a, "&quot;") catch {},
        '\'' => out.appendSlice(a, "&#39;") catch {},
        else => out.append(a, c) catch {},
    };
    return out.items;
}

fn errFrag(a: Allocator) []const u8 {
    _ = a;
    return "<p class=\"text-rose-400\">render error — check the server log</p>";
}

/// Path portion of a request target, query string stripped.
fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

/// Parse `?key=N` (unsigned) from a request target.
fn queryUint(target: []const u8, key: []const u8) ?usize {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eqp = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eqp], key))
            return std.fmt.parseInt(usize, pair[eqp + 1 ..], 10) catch null;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// --- in-app article reader (same-origin proxy) ------------------------------
// News/regulatory pages set X-Frame-Options / CSP frame-ancestors, so a direct
// iframe of the real URL usually refuses to render. This endpoint fetches the
// page server-side and re-serves it same-origin (without the framing headers)
// so it can display inside the dashboard's reader drawer. To avoid becoming an
// open proxy, it only serves URLs the monitor has actually recorded.

// In-process cache of processed reader HTML. The remote fetch dominates reader
// latency (seconds per open); a long-lived serve process can serve repeat opens
// of the same article instantly. The accept loop is single-threaded, so no
// locking is needed. Entries live in the page allocator (outlive the per-request
// arena) and are evicted oldest-first once the table is full.
const reader_cache_cap = 48;
const reader_cache_ttl_ms: i64 = 15 * 60 * 1000;

const ReaderEntry = struct {
    url: []u8,
    html: []u8,
    ts_ms: i64,
};

var reader_cache_entries: [reader_cache_cap]?ReaderEntry = [_]?ReaderEntry{null} ** reader_cache_cap;

fn readerCacheGet(url: []const u8, now_ms: i64) ?[]const u8 {
    for (&reader_cache_entries) |*slot| {
        if (slot.*) |e| {
            if (std.mem.eql(u8, e.url, url) and now_ms - e.ts_ms < reader_cache_ttl_ms) return e.html;
        }
    }
    return null;
}

fn readerCachePut(url: []const u8, html: []const u8, now_ms: i64) void {
    const ga = std.heap.page_allocator;
    var target: usize = 0;
    var chosen = false;
    // Prefer an existing entry for this url (refresh it in place).
    for (&reader_cache_entries, 0..) |*slot, i| {
        if (slot.*) |e| {
            if (std.mem.eql(u8, e.url, url)) {
                target = i;
                chosen = true;
                break;
            }
        }
    }
    // Else prefer an empty slot.
    if (!chosen) {
        for (reader_cache_entries, 0..) |slot, i| {
            if (slot == null) {
                target = i;
                chosen = true;
                break;
            }
        }
    }
    // Else evict the oldest entry.
    if (!chosen) {
        var oldest: i64 = std.math.maxInt(i64);
        for (reader_cache_entries, 0..) |slot, i| {
            if (slot) |e| {
                if (e.ts_ms < oldest) {
                    oldest = e.ts_ms;
                    target = i;
                }
            }
        }
    }
    if (reader_cache_entries[target]) |old| {
        ga.free(old.url);
        ga.free(old.html);
        reader_cache_entries[target] = null;
    }
    const url_copy = ga.dupe(u8, url) catch return;
    const html_copy = ga.dupe(u8, html) catch {
        ga.free(url_copy);
        return;
    };
    reader_cache_entries[target] = .{ .url = url_copy, .html = html_copy, .ts_ms = now_ms };
}

fn renderReader(ctx: *Context, cache: *Cache, target: []const u8) ![]const u8 {
    const a = ctx.arena;
    const raw = queryRaw(target, "url") orelse return readerError(a, "no url provided");
    const url = percentDecode(a, raw);
    const is_http = std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
    if (!is_http) return readerError(a, "unsupported url scheme");
    const now_ms = Io.Timestamp.now(ctx.io, .real).toMilliseconds();
    // A cached entry was allowlisted when stored, so serve it before paying the
    // allowlist's event-log decompression cost.
    if (readerCacheGet(url, now_ms)) |cached| return cached;
    if (!urlAllowed(ctx, cache, url)) return readerError(a, "this url is not in the monitor's records");
    // Browser UA: several sources (federalregister.gov, ecfr.gov) serve a
    // "Request Access" CAPTCHA wall to a non-browser UA. This on-demand,
    // user-initiated fetch presents a browser identity to get the real article.
    const html = fetch.httpGetBrowser(ctx, url) catch
        return readerError(a, "could not load this source. it may block embedding — use the external link (top-right) to open it in a new tab.");
    // If the source still returned a bot-block / CAPTCHA page, don't render the
    // broken wall inside the drawer — show a clean message pointing at the ↗.
    if (looksBlocked(html))
        return readerError(a, "this source is blocking automated access (a CAPTCHA / \"request access\" wall). use the external link (top-right) to open it in a new tab.");
    // Strip client-side scripts: we want the server-rendered article, not a
    // hydration that fails cross-origin (SPA pages otherwise show their own
    // "couldn't load" boundary). CSS/images still resolve via the injected base.
    const stripped = stripScripts(a, html) catch html;
    const doc = try injectBase(a, stripped, url);
    readerCachePut(url, doc, now_ms);
    return doc;
}

/// Heuristic: does this page look like a bot-block / CAPTCHA interstitial rather
/// than the article? Requires a CAPTCHA/challenge widget *and* an access-wall
/// phrase, so a normal article that merely mentions "captcha" won't trip it.
fn looksBlocked(html: []const u8) bool {
    const has_widget = containsI(html, "g-recaptcha") or containsI(html, "recaptcha/api") or
        containsI(html, "hcaptcha") or containsI(html, "cf-challenge") or containsI(html, "/cdn-cgi/challenge");
    if (!has_widget) return false;
    return containsI(html, "request access") or containsI(html, "verify you are human") or
        containsI(html, "just a moment") or containsI(html, "attention required") or
        containsI(html, "enable javascript and cookies");
}

fn containsI(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// Remove every `<script>…</script>` block (case-insensitive). Leaves inline
/// styles, `<noscript>` fallbacks, and all markup intact.
fn stripScripts(a: Allocator, html: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = html;
    while (std.ascii.indexOfIgnoreCase(rest, "<script")) |s| {
        try out.appendSlice(a, rest[0..s]);
        const after = rest[s..];
        if (std.ascii.indexOfIgnoreCase(after, "</script")) |c| {
            const tail = after[c..];
            if (std.mem.indexOfScalar(u8, tail, '>')) |gt| {
                rest = tail[gt + 1 ..];
                continue;
            }
        }
        rest = ""; // unterminated <script>: drop the remainder
        break;
    }
    try out.appendSlice(a, rest);
    return out.items;
}

/// Allowlist gate: the URL must appear in the observation log or an alert. This
/// keeps the proxy usable only for content the poller has already surfaced.
fn urlAllowed(ctx: *Context, cache: *Cache, url: []const u8) bool {
    const rows = cache.events(ctx);
    for (rows) |e| if (eql(e.url, url)) return true;
    const st = cache.state(ctx);
    for (st.alerts) |al| if (eql(al.url, url)) return true;
    return false;
}

/// Inject a `<base>` so the fetched page's relative assets/links resolve against
/// its real origin (and in-frame navigation stays in the drawer).
fn injectBase(a: Allocator, html: []const u8, url: []const u8) ![]const u8 {
    const base_tag = try std.fmt.allocPrint(a, "<base href=\"{s}\" target=\"_self\">", .{esc(a, url)});
    if (std.ascii.indexOfIgnoreCase(html, "<head")) |h| {
        if (std.mem.indexOfScalarPos(u8, html, h, '>')) |gt| {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, html[0 .. gt + 1]);
            try out.appendSlice(a, base_tag);
            try out.appendSlice(a, html[gt + 1 ..]);
            return out.items;
        }
    }
    return std.fmt.allocPrint(a, "{s}{s}", .{ base_tag, html });
}

/// A minimal, on-theme HTML page shown inside the reader iframe on any failure.
fn readerError(a: Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(a,
        "<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{{margin:0;height:100%;background:#000;color:#fff;" ++
            "font-family:'Roboto Mono',ui-monospace,monospace;display:flex;align-items:center;justify-content:center;}}" ++
            "p{{padding:24px;font-size:13px;letter-spacing:.02em;color:#e8e8e8;text-align:center;max-width:520px;line-height:1.7;}}" ++
            "</style></head><body><p>{s}</p></body></html>",
        .{esc(a, msg)},
    ) catch "<p>reader error</p>";
}

/// Raw (still percent-encoded) value of `?key=...` from a request target.
fn queryRaw(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eqp = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eqp], key)) return pair[eqp + 1 ..];
    }
    return null;
}

fn percentDecode(a: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                out.append(a, hi.? * 16 + lo.?) catch {};
                i += 2;
                continue;
            }
            out.append(a, s[i]) catch {};
        } else if (s[i] == '+') {
            out.append(a, ' ') catch {};
        } else {
            out.append(a, s[i]) catch {};
        }
    }
    return out.items;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// --- static page shell ------------------------------------------------------
// Tailwind v4 (browser build) + htmx, both from a CDN so there is no build step.
// htmx polls the /ui/* fragment endpoints and swaps their HTML in place.

const shell =
    \\<!doctype html>
    \\<html lang="en" class="dark">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>fable-monitor</title>
    \\<link rel="preconnect" href="https://fonts.googleapis.com">
    \\<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    \\<link href="https://fonts.googleapis.com/css2?family=Roboto+Mono:wght@400;500&display=swap" rel="stylesheet">
    \\<link href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.31.0/dist/tabler-icons.min.css" rel="stylesheet">
    \\<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    \\<script src="https://unpkg.com/htmx.org@2.0.3"></script>
    \\<style type="text/tailwindcss">
    \\@theme {
    \\  --font-sans: "Roboto Mono", ui-monospace, monospace;
    \\  --font-mono: "Roboto Mono", ui-monospace, monospace;
    \\  --color-slate-950: #000000;
    \\  --color-slate-900: #000000;
    \\  --color-slate-800: #595959;
    \\  --color-slate-700: #4d4d4d;
    \\  --color-slate-600: #595959;
    \\  --color-slate-500: #595959;
    \\  --color-slate-400: #9a9a9a;
    \\  --color-slate-300: #e8e8e8;
    \\  --color-slate-200: #ffffff;
    \\  --color-emerald-400: #ffffff;
    \\  --color-emerald-300: #ffffff;
    \\  --color-rose-400: #ffffff;
    \\  --color-rose-300: #ffffff;
    \\  --color-amber-300: #e8e8e8;
    \\  --color-sky-400: #ffffff;
    \\  --color-sky-300: #e8e8e8;
    \\}
    \\</style>
    \\<style>
    \\:root{--jet:#000;--grid:#595959;--dim:#9a9a9a;--mute:#e8e8e8;--bar-off:#4d4d4d;--fg:#fff;--mono:"Roboto Mono",ui-monospace,monospace;}
    \\*{border-radius:0 !important;}
    \\html,body{font-family:var(--mono) !important;}
    \\body{background:linear-gradient(180deg,#151515 0%,#000 100%) !important;color:var(--fg) !important;min-height:100vh;-webkit-font-smoothing:antialiased;letter-spacing:.01em;}
    \\*{scrollbar-width:thin;scrollbar-color:#595959 #0a0a0a;}
    \\::-webkit-scrollbar{width:10px;height:10px;}
    \\::-webkit-scrollbar-track{background:#0a0a0a;}
    \\::-webkit-scrollbar-thumb{background:#595959;}
    \\::-webkit-scrollbar-thumb:hover{background:#fff;}
    \\.ti{font-size:20px;line-height:1;vertical-align:-2px;color:#fff;}
    \\.cc-title{font-weight:500;letter-spacing:.02em;text-transform:lowercase;color:#fff;}
    \\.cc-live{display:inline-block;height:7px;width:7px;background:#fff;animation:cc-blink 2.4s steps(1) infinite;}
    \\@keyframes cc-blink{0%,62%{opacity:1;}63%,100%{opacity:.25;}}
    \\.cc-motto{display:inline-block;font-size:13px;letter-spacing:.24em;text-transform:uppercase;background:linear-gradient(100deg,#9a9a9a 0%,#e8e8e8 42%,#fff 50%,#e8e8e8 58%,#9a9a9a 100%);background-size:200% auto;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent;animation:cc-liquid 16s linear infinite;}
    \\@keyframes cc-liquid{to{background-position:200% center;}}
    \\.cc-key{color:#595959;text-transform:lowercase;letter-spacing:.06em;font-size:15px;}
    \\span[class*="-500/20"]{border-radius:0 !important;padding:1px 8px !important;font-size:12px !important;letter-spacing:.04em;text-transform:uppercase;line-height:1.6;}
    \\span[class*="rose-500"],span[class*="emerald-500"]{background:#fff !important;color:#000 !important;border:0 !important;font-weight:500 !important;}
    \\span[class*="amber-500"]{background:#000 !important;color:#fff !important;border:1px solid #fff !important;}
    \\span[class*="sky-500"]{background:#000 !important;color:#9a9a9a !important;border:1px solid #595959 !important;}
    \\span[class*="slate-700"]{background:#000 !important;color:#4d4d4d !important;border:1px solid #4d4d4d !important;border-radius:0 !important;padding:1px 8px !important;font-size:12px !important;text-transform:uppercase;letter-spacing:.04em;}
    \\a[class*="sky-400"]{color:#fff !important;text-decoration:none;}
    \\a[class*="sky-400"]:hover{text-decoration:underline;}
    \\tr[class*="hover:bg-slate-800"]:hover{background:#141414 !important;}
    \\a.reader-link{cursor:pointer;}
    \\a.reader-ext{color:#595959 !important;text-decoration:none;margin-left:2px;}
    \\a.reader-ext:hover{color:#fff !important;}
    \\.pager-bar{display:flex;align-items:center;justify-content:flex-end;gap:10px;padding:8px 12px;border-top:1px solid #595959;background:#0a0a0a;font-size:12px;}
    \\.pg-ind{color:#9a9a9a;letter-spacing:.04em;min-width:120px;text-align:center;}
    \\.pg-btn{border:1px solid #595959;background:#000;color:#fff;padding:2px 10px;font-family:var(--mono);font-size:12px;letter-spacing:.04em;text-transform:lowercase;cursor:pointer;}
    \\.pg-btn:hover:not(:disabled){background:#fff;color:#000;}
    \\.pg-btn:disabled{color:#4d4d4d;border-color:#333;cursor:default;}
    \\.reader-overlay{position:fixed;inset:0;z-index:60;display:none;}
    \\.reader-overlay.open{display:block;}
    \\.reader-backdrop{position:absolute;inset:0;background:rgba(0,0,0,.74);}
    \\.reader-panel{position:absolute;top:0;right:0;height:100vh;width:min(960px,95vw);background:#000;border-left:1px solid #595959;display:flex;flex-direction:column;box-shadow:-24px 0 60px rgba(0,0,0,.6);}
    \\.reader-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:10px 14px;border-bottom:1px solid #595959;background:#0a0a0a;flex:none;}
    \\.reader-titletext{font-size:13px;letter-spacing:.02em;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
    \\.reader-actions{display:flex;align-items:center;gap:6px;flex:none;}
    \\.reader-act{display:inline-flex;align-items:center;justify-content:center;height:30px;width:30px;border:1px solid #595959;background:#000;color:#fff;cursor:pointer;text-decoration:none;}
    \\.reader-act:hover{background:#fff;}
    \\.reader-act:hover .ti{color:#000;}
    \\.reader-frame{flex:1;width:100%;border:0;background:#fff;}
    \\.cc-search{display:flex;align-items:center;gap:10px;border:1px solid #595959;background:#0a0a0a;padding:10px 14px;transition:border-color .15s;}
    \\.cc-search:focus-within{border-color:#fff;}
    \\.cc-search .ti{color:#9a9a9a;font-size:18px;}
    \\.cc-search:focus-within .ti{color:#fff;}
    \\#cc-search{flex:1;background:transparent;border:0;outline:none;color:#fff;font-family:var(--mono);font-size:14px;letter-spacing:.02em;padding:0;}
    \\#cc-search::placeholder{color:#595959;text-transform:lowercase;}
    \\.cc-search-meta{color:#9a9a9a;font-size:11px;letter-spacing:.06em;white-space:nowrap;text-transform:uppercase;}
    \\.cc-kbd{border:1px solid #4d4d4d;color:#9a9a9a;padding:0 6px;font-size:11px;line-height:18px;background:#000;}
    \\.cc-results{margin-top:8px;border:1px solid #595959;background:#000;max-height:62vh;overflow:auto;}
    \\.cc-res-row{display:grid;grid-template-columns:auto auto minmax(0,1fr) auto;gap:12px;align-items:center;padding:9px 12px;border-top:1px solid #1e1e1e;cursor:pointer;}
    \\.cc-res-row:first-child{border-top:0;}
    \\.cc-res-row:hover{background:#141414;}
    \\.cc-res-row[data-reader-url]{cursor:pointer;}
    \\.cc-res-row:not([data-reader-url]){cursor:default;}
    \\.cc-tier{display:inline-block;min-width:30px;text-align:center;padding:1px 7px;font-size:11px;letter-spacing:.04em;text-transform:uppercase;border:1px solid #595959;color:#fff;background:#000;line-height:1.6;}
    \\.cc-tier.t1{background:#fff;color:#000;border-color:#fff;font-weight:500;}
    \\.cc-tier.t2{background:#000;color:#fff;border-color:#fff;}
    \\.cc-tier.t3{background:#000;color:#9a9a9a;border-color:#595959;}
    \\.cc-res-src{color:#9a9a9a;font-size:11px;font-family:var(--mono);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:150px;}
    \\.cc-res-title{color:#fff;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;}
    \\.cc-res-title .cc-hit{color:#000;background:#fff;padding:0 1px;}
    \\.cc-res-when{color:#595959;font-size:11px;white-space:nowrap;}
    \\.cc-res-empty{padding:18px;color:#595959;font-size:12px;text-align:center;letter-spacing:.02em;}
    \\@media (prefers-reduced-motion:reduce){.cc-motto,.cc-live{animation:none !important;}}
    \\</style>
    \\</head>
    \\<body class="min-h-screen antialiased">
    \\<div class="mx-auto max-w-6xl px-4 py-8">
    \\  <header class="mb-6 flex items-end justify-between border-b border-slate-800 pb-4">
    \\    <div>
    \\      <h1 class="cc-title text-xl"><i class="ti ti-radar-2"></i> fable-monitor</h1>
    \\      <p class="mt-2"><span class="cc-motto">standing watch</span></p>
    \\      <p class="mt-1 text-sm text-slate-500">fable 5 / mythos 5 export-control access watch</p>
    \\    </div>
    \\    <div class="flex items-center gap-2 text-xs text-slate-500">
    \\      <span class="cc-live"></span>
    \\      live &middot; auto-refresh 5s
    \\    </div>
    \\  </header>
    \\
    \\  <section hx-get="/ui/status" hx-trigger="load, every 5s" hx-swap="innerHTML" class="mb-6">
    \\    <div class="text-sm text-slate-600">loading status&hellip;</div>
    \\  </section>
    \\
    \\  <section class="mb-6">
    \\    <div class="cc-search">
    \\      <i class="ti ti-search"></i>
    \\      <input id="cc-search" type="text" placeholder="search events & alerts&hellip;" autocomplete="off" autocapitalize="off" spellcheck="false" aria-label="search events and alerts">
    \\      <span class="cc-kbd">/</span>
    \\      <span id="cc-search-meta" class="cc-search-meta">indexing&hellip;</span>
    \\    </div>
    \\    <div id="cc-results" class="cc-results" hidden></div>
    \\  </section>
    \\
    \\  <section class="mb-6">
    \\    <h2 class="cc-key mb-2">active_alerts</h2>
    \\    <div class="overflow-hidden border border-slate-800 bg-slate-900/60" data-pager="alerts"
    \\         hx-get="/ui/alerts" hx-trigger="load, every 5s" hx-swap="innerHTML">
    \\      <div class="p-4 text-sm text-slate-600">loading&hellip;</div>
    \\    </div>
    \\  </section>
    \\
    \\  <section class="mb-6">
    \\    <h2 class="cc-key mb-2">sources</h2>
    \\    <div class="overflow-hidden border border-slate-800 bg-slate-900/60" data-pager="sources"
    \\         hx-get="/ui/sources" hx-trigger="load, every 30s" hx-swap="innerHTML">
    \\      <div class="p-4 text-sm text-slate-600">loading&hellip;</div>
    \\    </div>
    \\  </section>
    \\
    \\  <section>
    \\    <h2 class="cc-key mb-2">recent_events</h2>
    \\    <div class="overflow-hidden border border-slate-800 bg-slate-900/60" data-pager="events"
    \\         hx-get="/ui/events?limit=60" hx-trigger="load, every 10s" hx-swap="innerHTML">
    \\      <div class="p-4 text-sm text-slate-600">loading&hellip;</div>
    \\    </div>
    \\  </section>
    \\
    \\  <footer class="mt-8 border-t border-slate-800 pt-4 text-center text-xs text-slate-600">
    \\    read-only &middot; binds 127.0.0.1 &middot; the scheduled poller owns the data
    \\  </footer>
    \\</div>
    \\
    \\<div id="reader-overlay" class="reader-overlay" aria-hidden="true">
    \\  <div class="reader-backdrop" data-reader-close></div>
    \\  <aside class="reader-panel" role="dialog" aria-label="article reader">
    \\    <header class="reader-head">
    \\      <span id="reader-title" class="reader-titletext">article</span>
    \\      <span class="reader-actions">
    \\        <a id="reader-ext" href="#" target="_blank" rel="noreferrer" class="reader-act" title="open in new tab"><i class="ti ti-external-link"></i></a>
    \\        <button type="button" data-reader-close class="reader-act" title="close (esc)"><i class="ti ti-x"></i></button>
    \\      </span>
    \\    </header>
    \\    <iframe id="reader-frame" class="reader-frame" src="about:blank" title="article reader"
    \\            sandbox="allow-same-origin allow-popups" referrerpolicy="no-referrer"></iframe>
    \\  </aside>
    \\</div>
    \\
    \\<script>
    \\(function(){
    \\  // In-app article reader drawer.
    \\  var overlay=document.getElementById('reader-overlay');
    \\  var frame=document.getElementById('reader-frame');
    \\  var titleEl=document.getElementById('reader-title');
    \\  var extLink=document.getElementById('reader-ext');
    \\  var readerSeq=0;
    \\  function frameDoc(msg){return '<!doctype html><meta charset="utf-8"><body style="margin:0;height:100vh;background:#000;color:#9a9a9a;font-family:ui-monospace,monospace;display:flex;align-items:center;justify-content:center;padding:24px;text-align:center;font-size:13px;line-height:1.7;letter-spacing:.03em;">'+msg+'</body>';}
    \\  function openReader(url,label){
    \\    titleEl.textContent=label||'article';
    \\    extLink.href=url;
    \\    overlay.classList.add('open');
    \\    overlay.setAttribute('aria-hidden','false');
    \\    document.body.style.overflow='hidden';
    \\    // Load via fetch (not an iframe src): the auth proxy passes fetch/XHR
    \\    // through, but hijacks iframe document navigations to its own shell.
    \\    // The fetched HTML is injected with srcdoc so it renders same-origin.
    \\    var seq=++readerSeq;
    \\    frame.removeAttribute('src');
    \\    frame.srcdoc=frameDoc('loading article&hellip;');
    \\    fetch('/reader?url='+encodeURIComponent(url),{headers:{'accept':'text/html'},credentials:'same-origin'})
    \\      .then(function(r){return r.text();})
    \\      .then(function(html){ if(seq===readerSeq&&overlay.classList.contains('open')) frame.srcdoc=html; })
    \\      .catch(function(){ if(seq===readerSeq) frame.srcdoc=frameDoc('could not load this source. use the external link (top-right) to open it in a new tab.'); });
    \\  }
    \\  function closeReader(){
    \\    readerSeq++;
    \\    overlay.classList.remove('open');
    \\    overlay.setAttribute('aria-hidden','true');
    \\    frame.srcdoc='';
    \\    frame.removeAttribute('src');
    \\    document.body.style.overflow='';
    \\  }
    \\  document.addEventListener('click',function(e){
    \\    var open=e.target.closest('[data-reader-url]');
    \\    if(open){e.preventDefault();openReader(open.getAttribute('data-reader-url'),open.getAttribute('data-reader-label'));return;}
    \\    if(e.target.closest('[data-reader-close]')){closeReader();}
    \\  });
    \\  document.addEventListener('keydown',function(e){
    \\    if(e.key==='Escape'&&overlay.classList.contains('open')){closeReader();}
    \\  });
    \\
    \\  // Client-side pagination that survives htmx swaps. Page index is kept per
    \\  // section so the live auto-refresh does not knock you back to page 1.
    \\  var SIZE={events:8,sources:8,alerts:8};
    \\  var pageIdx={};
    \\  function pager(container){
    \\    var key=container.getAttribute('data-pager');
    \\    if(!key)return;
    \\    var table=container.querySelector('table');
    \\    var tbody=table?table.querySelector('tbody'):null;
    \\    var old=container.querySelector('.pager-bar');
    \\    if(old)old.remove();
    \\    if(!tbody)return;
    \\    var rows=Array.prototype.slice.call(tbody.children).filter(function(r){
    \\      return !(r.children.length===1&&r.children[0].hasAttribute('colspan'));
    \\    });
    \\    var size=SIZE[key]||8;
    \\    if(rows.length<=size){rows.forEach(function(r){r.style.display='';});return;}
    \\    var pages=Math.ceil(rows.length/size);
    \\    var p=pageIdx[key]||0;
    \\    if(p>=pages)p=pages-1;
    \\    if(p<0)p=0;
    \\    pageIdx[key]=p;
    \\    rows.forEach(function(r,i){r.style.display=(i>=p*size&&i<(p+1)*size)?'':'none';});
    \\    var bar=document.createElement('div');
    \\    bar.className='pager-bar';
    \\    var prev=document.createElement('button');
    \\    prev.className='pg-btn';prev.type='button';prev.textContent='‹ prev';prev.disabled=(p===0);
    \\    prev.addEventListener('click',function(){if(pageIdx[key]>0){pageIdx[key]--;pager(container);}});
    \\    var ind=document.createElement('span');
    \\    ind.className='pg-ind';
    \\    ind.textContent=(p*size+1)+'–'+Math.min((p+1)*size,rows.length)+' / '+rows.length;
    \\    var next=document.createElement('button');
    \\    next.className='pg-btn';next.type='button';next.textContent='next ›';next.disabled=(p===pages-1);
    \\    next.addEventListener('click',function(){if(pageIdx[key]<pages-1){pageIdx[key]++;pager(container);}});
    \\    bar.appendChild(prev);bar.appendChild(ind);bar.appendChild(next);
    \\    container.appendChild(bar);
    \\  }
    \\  function applyAll(){document.querySelectorAll('[data-pager]').forEach(pager);}
    \\  document.body.addEventListener('htmx:afterSwap',function(e){
    \\    var c=e.target&&e.target.closest?e.target.closest('[data-pager]'):null;
    \\    if(c)pager(c);else applyAll();
    \\  });
    \\  document.addEventListener('DOMContentLoaded',applyAll);
    \\})();
    \\</script>
    \\
    \\<script type="module">
    \\import { create, insertMultiple, search } from 'https://esm.sh/@orama/orama@3';
    \\(async function(){
    \\  var input=document.getElementById('cc-search');
    \\  var results=document.getElementById('cc-results');
    \\  var meta=document.getElementById('cc-search-meta');
    \\  if(!input) return;
    \\  var db=null, count=0, loadedAt=0, building=null;
    \\  function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
    \\  function rx(s){return s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');}
    \\  function tierBadge(t){var n=(t>=1&&t<=3)?t:0;return '<span class="cc-tier '+(n?'t'+n:'')+'">'+(n?'T'+n:'—')+'</span>';}
    \\  function highlight(title,term){
    \\    var out=esc(title);
    \\    var toks=term.split(/\s+/).filter(function(w){return w.length>=2;});
    \\    toks.forEach(function(w){
    \\      try{out=out.replace(new RegExp('('+rx(esc(w))+')','ig'),'<span class="cc-hit">$1</span>');}catch(e){}
    \\    });
    \\    return out;
    \\  }
    \\  async function build(){
    \\    if(building) return building;
    \\    building=(async function(){
    \\      try{
    \\        var res=await fetch('/ui/search-index',{headers:{'accept':'application/json'}});
    \\        var docs=await res.json();
    \\        docs.forEach(function(x,i){x.id=String(i);});
    \\        var d=create({schema:{title:'string',source:'string',kind:'string',detail:'string',event:'string',tier:'number',url:'string',when:'string',ts:'number'}});
    \\        await insertMultiple(d,docs);
    \\        db=d; count=docs.length; loadedAt=Date.now();
    \\        if(!input.value.trim()) meta.textContent=count+' indexed';
    \\      }catch(err){ meta.textContent='index unavailable'; }
    \\      building=null;
    \\    })();
    \\    return building;
    \\  }
    \\  function render(r,term){
    \\    results.hidden=false;
    \\    if(!r.hits.length){
    \\      results.innerHTML='<div class="cc-res-empty">no matches for &ldquo;'+esc(term)+'&rdquo;</div>';
    \\      meta.textContent='0 results'; return;
    \\    }
    \\    meta.textContent=r.count+' result'+(r.count===1?'':'s');
    \\    results.innerHTML=r.hits.map(function(h){
    \\      var doc=h.document;
    \\      var isHttp=/^https?:\/\//i.test(doc.url||'');
    \\      var attrs=isHttp?(' data-reader-url="'+esc(doc.url)+'" data-reader-label="'+esc(doc.title)+'"'):'';
    \\      return '<div class="cc-res-row"'+attrs+'>'+
    \\        tierBadge(doc.tier)+
    \\        '<span class="cc-res-src">'+esc(doc.source||'')+'</span>'+
    \\        '<span class="cc-res-title">'+highlight(doc.title||'(untitled)',term)+'</span>'+
    \\        '<span class="cc-res-when">'+esc(doc.when||'')+'</span>'+
    \\      '</div>';
    \\    }).join('');
    \\  }
    \\  async function run(){
    \\    var term=input.value.trim();
    \\    if(!term){ results.hidden=true; results.innerHTML=''; if(db) meta.textContent=count+' indexed'; return; }
    \\    if(!db){ await build(); }
    \\    if(!db){ return; }
    \\    try{
    \\      var r=await search(db,{term:term,properties:['title','source','detail','kind','event'],limit:40,tolerance:1,boost:{title:2,source:1.2}});
    \\      render(r,term);
    \\    }catch(e){ meta.textContent='search error'; }
    \\  }
    \\  var t=null;
    \\  input.addEventListener('input',function(){clearTimeout(t);t=setTimeout(run,140);});
    \\  input.addEventListener('focus',function(){ if(!db||Date.now()-loadedAt>60000) build(); });
    \\  document.addEventListener('keydown',function(e){
    \\    var tag=(document.activeElement&&document.activeElement.tagName||'').toLowerCase();
    \\    if(e.key==='/'&&tag!=='input'&&tag!=='textarea'){ e.preventDefault(); input.focus(); input.select(); return; }
    \\    if(e.key==='Escape'&&document.activeElement===input){
    \\      if(input.value){ input.value=''; run(); } else { input.blur(); }
    \\    }
    \\  });
    \\  build();
    \\})();
    \\</script>
    \\</body>
    \\</html>
;

// --- tests --------------------------------------------------------------------

test "detailCell allowlists http/https and renders other schemes as text" {
    var ta = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ta.deinit();
    const a = ta.allocator();

    // http/https (any case) get an anchor.
    try std.testing.expect(std.mem.indexOf(u8, detailCell(a, "t", "https://example.com/x"), "<a href=\"https://example.com/x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, detailCell(a, "t", "http://example.com"), "<a href=") != null);
    try std.testing.expect(std.mem.indexOf(u8, detailCell(a, "t", "HtTpS://example.com"), "<a href=") != null);

    // Everything else renders as escaped plain text, never an anchor.
    for ([_][]const u8{
        "javascript:alert(1)",
        "data:text/html,<script>1</script>",
        "file:///etc/passwd",
        "vbscript:x",
        "//example.com/scheme-relative",
        "httpx://not-http",
    }) |bad| {
        const cell = detailCell(a, "t", bad);
        try std.testing.expect(std.mem.indexOf(u8, cell, "<a ") == null);
    }
    // The hostile URL is escaped on the plain-text path.
    const data_cell = detailCell(a, "t", "data:text/html,<script>1</script>");
    try std.testing.expect(std.mem.indexOf(u8, data_cell, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, data_cell, "&lt;script&gt;") != null);

    // No URL: text passes through untouched.
    try std.testing.expectEqualStrings("t", detailCell(a, "t", ""));
}

test "parseEventLog parses, sorts ascending, and copies strings out of the input" {
    var ta = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ta.deinit();
    const a = ta.allocator();

    const src =
        "{\"event\":\"advisory\",\"epoch_ms\":2000,\"source_id\":\"s2\"}\n" ++
        "not json\n" ++
        "\n" ++
        "{\"event\":\"baseline\",\"epoch_ms\":1000,\"source_id\":\"s1\"}\n";
    var buf: [src.len]u8 = undefined;
    @memcpy(&buf, src);

    const rows = try parseEventLog(a, &buf);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(i64, 1000), rows[0].epoch_ms);
    try std.testing.expectEqual(@as(i64, 2000), rows[1].epoch_ms);

    // Clobber the input buffer: parsed strings must survive (`.alloc_always`),
    // which is what lets the cache free its scratch per request.
    @memset(&buf, 'x');
    try std.testing.expectEqualStrings("s1", rows[0].source_id);
    try std.testing.expectEqualStrings("advisory", rows[1].event);
}

test "Cache re-parses events only when the mtime moves" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    // Nothing cached yet: any mtime misses, including the missing-file marker.
    try std.testing.expect(cache.cachedEventsFor(Cache.mtime_missing) == null);
    try std.testing.expect(cache.cachedEventsFor(100) == null);

    const first = cache.refreshEvents(100, "{\"event\":\"baseline\",\"epoch_ms\":1}");
    try std.testing.expectEqual(@as(usize, 1), first.len);

    // Same mtime: the cached slice comes back untouched — no re-parse.
    const hit = cache.cachedEventsFor(100) orelse return error.TestExpectedCacheHit;
    try std.testing.expectEqual(first.ptr, hit.ptr);
    try std.testing.expectEqual(first.len, hit.len);

    // Different mtime: stale, and a refresh replaces the parse.
    try std.testing.expect(cache.cachedEventsFor(101) == null);
    const second = cache.refreshEvents(101, "{\"epoch_ms\":1}\n{\"epoch_ms\":2}");
    try std.testing.expectEqual(@as(usize, 2), second.len);
    try std.testing.expectEqual(@as(usize, 2), cache.cachedEventsFor(101).?.len);
    try std.testing.expect(cache.cachedEventsFor(100) == null);
}
