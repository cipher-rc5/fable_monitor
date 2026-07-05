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
    // Only http/https URLs earn a clickable anchor; anything else (javascript:,
    // data:, file:, …) is rendered as escaped plain text so a hostile URL in
    // the log can never become a live link.
    if (!urlSchemeAllowed(url)) {
        return std.fmt.allocPrint(a, "{s} <span class=\"text-slate-500 text-xs\">{s}</span>", .{ text, esc(a, url) }) catch text;
    }
    return std.fmt.allocPrint(a, "{s} <a href=\"{s}\" target=\"_blank\" rel=\"noreferrer\" class=\"text-sky-400 hover:underline\">↗</a>", .{ text, esc(a, url) }) catch text;
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
    \\<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    \\<script src="https://unpkg.com/htmx.org@2.0.3"></script>
    \\</head>
    \\<body class="min-h-screen bg-slate-950 text-slate-200 antialiased">
    \\<div class="mx-auto max-w-6xl px-4 py-8">
    \\  <header class="mb-6 flex items-center justify-between">
    \\    <div>
    \\      <h1 class="text-xl font-semibold tracking-tight">fable-monitor</h1>
    \\      <p class="text-sm text-slate-500">Fable 5 / Mythos 5 export-control access watch</p>
    \\    </div>
    \\    <div class="flex items-center gap-2 text-xs text-slate-500">
    \\      <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-emerald-400"></span>
    \\      live · auto-refresh 5s
    \\    </div>
    \\  </header>
    \\
    \\  <section hx-get="/ui/status" hx-trigger="load, every 5s" hx-swap="innerHTML" class="mb-6">
    \\    <div class="animate-pulse text-sm text-slate-600">loading status…</div>
    \\  </section>
    \\
    \\  <section class="mb-6">
    \\    <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-slate-400">Active alerts</h2>
    \\    <div class="overflow-hidden rounded-lg border border-slate-800 bg-slate-900/60"
    \\         hx-get="/ui/alerts" hx-trigger="load, every 5s" hx-swap="innerHTML">
    \\      <div class="animate-pulse p-4 text-sm text-slate-600">loading…</div>
    \\    </div>
    \\  </section>
    \\
    \\  <section class="mb-6">
    \\    <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-slate-400">Sources</h2>
    \\    <div class="overflow-hidden rounded-lg border border-slate-800 bg-slate-900/60"
    \\         hx-get="/ui/sources" hx-trigger="load, every 30s" hx-swap="innerHTML">
    \\      <div class="animate-pulse p-4 text-sm text-slate-600">loading…</div>
    \\    </div>
    \\  </section>
    \\
    \\  <section>
    \\    <h2 class="mb-2 text-sm font-semibold uppercase tracking-wide text-slate-400">Recent events</h2>
    \\    <div class="overflow-hidden rounded-lg border border-slate-800 bg-slate-900/60"
    \\         hx-get="/ui/events?limit=30" hx-trigger="load, every 10s" hx-swap="innerHTML">
    \\      <div class="animate-pulse p-4 text-sm text-slate-600">loading…</div>
    \\    </div>
    \\  </section>
    \\
    \\  <footer class="mt-8 text-center text-xs text-slate-600">
    \\    read-only · binds 127.0.0.1 · the scheduled poller owns the data
    \\  </footer>
    \\</div>
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
