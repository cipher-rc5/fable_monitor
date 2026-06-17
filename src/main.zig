//! fable-monitor: watches official sources for changes to the US government
//! export-control status of Anthropic's Fable 5 / Mythos 5 models.
//!
//! Design: one run = one poll. Intended to be driven by launchd or cron.
//! Fetching is delegated to the system `curl` binary (ubiquitous, handles TLS),
//! everything else is std-only Zig. State persists to a small JSON file so each
//! run can diff against the last and only alert on genuine changes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const version = "0.1.0";
const user_agent = "fable-monitor/" ++ version;
const fetch_timeout_s = "30";

/// Keywords that mark a fetched page as relevant. Case-insensitive.
const keywords = [_][]const u8{ "fable", "mythos", "anthropic" };

const SourceKind = enum {
    /// Federal Register JSON API: track newly published document numbers.
    federal_register,
    /// Generic page: hash only the keyword-bearing context and diff that.
    keyword_watch,
};

const Source = struct {
    id: []const u8,
    kind: SourceKind,
    url: []const u8,
    label: []const u8,
    /// Keywords that mark content from this source as high-signal. For
    /// keyword_watch sources this is also the set whose context is diffed.
    match: []const []const u8 = &keywords,
};

const sources = [_]Source{
    .{
        .id = "fr_anthropic",
        .kind = .federal_register,
        .label = "Federal Register (term: Anthropic)",
        .url = "https://www.federalregister.gov/api/v1/documents.json" ++
            "?per_page=20&order=newest&conditions%5Bterm%5D=Anthropic",
    },
    .{
        .id = "fr_bis",
        .kind = .federal_register,
        .label = "Federal Register (Bureau of Industry and Security rules)",
        .url = "https://www.federalregister.gov/api/v1/documents.json" ++
            "?per_page=20&order=newest&conditions%5Bagencies%5D%5B%5D=industry-and-security-bureau",
    },
    .{
        .id = "anthropic_news",
        .kind = .keyword_watch,
        .label = "Anthropic newsroom",
        .url = "https://www.anthropic.com/news",
        // "anthropic" appears site-wide here, so key on the model names only.
        .match = &.{ "fable", "mythos" },
    },
    .{
        .id = "bis_news",
        .kind = .keyword_watch,
        .label = "Bureau of Industry and Security news",
        .url = "https://www.bis.gov/news-updates",
    },
};

// State schema, serialized to JSON. Kept deliberately flat.
const State = struct {
    federal_register_seen: [][]const u8 = &.{},
    keyword_hashes: []KeywordHash = &.{},

    const KeywordHash = struct {
        id: []const u8,
        hash: []const u8,
    };

    fn hashFor(self: State, id: []const u8) ?[]const u8 {
        for (self.keyword_hashes) |kh| {
            if (std.mem.eql(u8, kh.id, id)) return kh.hash;
        }
        return null;
    }

    fn hasSeen(self: State, doc: []const u8) bool {
        for (self.federal_register_seen) |d| {
            if (std.mem.eql(u8, d, doc)) return true;
        }
        return false;
    }
};

// Minimal projection of the Federal Register API response.
const FrResponse = struct {
    results: []FrDoc = &.{},
};
const FrDoc = struct {
    document_number: []const u8 = "",
    title: []const u8 = "",
    publication_date: []const u8 = "",
    html_url: []const u8 = "",
};

const Context = struct {
    io: Io,
    arena: Allocator,
    state_path: []const u8,
    notify_cmd: ?[]const u8,
    changed: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const state_path: []const u8 = init.environ_map.get("FABLE_MONITOR_STATE") orelse
        "fable_monitor_state.json";
    const notify_cmd: ?[]const u8 = init.environ_map.get("FABLE_MONITOR_NOTIFY");

    var ctx = Context{
        .io = io,
        .arena = arena,
        .state_path = state_path,
        .notify_cmd = notify_cmd,
    };

    log("fable-monitor {s} polling {d} sources", .{ version, sources.len });

    // Fetching is delegated to system curl; bail early with a clear message
    // rather than letting every source fail with an opaque spawn error.
    if (!curlAvailable(&ctx)) {
        log("fatal: `curl` not found on PATH; fable-monitor requires the system curl binary. Install it or add it to PATH.", .{});
        return;
    }

    // Load previous state (empty on first run / missing file).
    var parsed_state: ?std.json.Parsed(State) = loadState(&ctx) catch |err| blk: {
        log("warning: could not read state ({s}); starting fresh", .{@errorName(err)});
        break :blk null;
    };
    defer if (parsed_state) |*p| p.deinit();
    const prev = if (parsed_state) |p| p.value else State{};

    // Accumulate next state as we go.
    var next_seen: std.ArrayList([]const u8) = .empty;
    var next_hashes: std.ArrayList(State.KeywordHash) = .empty;
    // Carry forward everything we already knew.
    for (prev.federal_register_seen) |d| try next_seen.append(arena, d);

    for (sources) |src| {
        switch (src.kind) {
            .federal_register => checkFederalRegister(&ctx, src, prev, &next_seen) catch |err| {
                log("error: source '{s}' failed: {s}", .{ src.id, @errorName(err) });
            },
            .keyword_watch => checkKeywordWatch(&ctx, src, prev, &next_hashes) catch |err| {
                log("error: source '{s}' failed: {s}", .{ src.id, @errorName(err) });
            },
        }
    }

    // Persist merged state.
    const next = State{
        .federal_register_seen = capTail(next_seen.items, 200),
        .keyword_hashes = next_hashes.items,
    };
    saveState(&ctx, next) catch |err| {
        log("error: failed to persist state: {s}", .{@errorName(err)});
    };

    if (!ctx.changed) {
        log("no changes detected", .{});
    }
}

fn checkFederalRegister(
    ctx: *Context,
    src: Source,
    prev: State,
    next_seen: *std.ArrayList([]const u8),
) !void {
    const body = try httpGet(ctx, src.url);
    const parsed = std.json.parseFromSlice(FrResponse, ctx.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log("source '{s}': JSON parse failed ({s})", .{ src.id, @errorName(err) });
        return;
    };
    defer parsed.deinit();

    var new_count: usize = 0;
    for (parsed.value.results) |doc| {
        if (doc.document_number.len == 0) continue;
        if (prev.hasSeen(doc.document_number)) continue;

        // New document. Record it and, if it looks relevant, alert.
        try next_seen.append(ctx.arena, try ctx.arena.dupe(u8, doc.document_number));
        new_count += 1;

        const haystack = try std.ascii.allocLowerString(ctx.arena, doc.title);
        const relevant = containsAny(haystack, src.match);
        const tag = if (relevant) "RELEVANT" else "new";
        try alert(ctx, try std.fmt.allocPrint(
            ctx.arena,
            "[{s}] Federal Register {s} doc {s} ({s}): {s}\n  {s}",
            .{ tag, src.label, doc.document_number, doc.publication_date, doc.title, doc.html_url },
        ), relevant);
    }

    if (new_count == 0) {
        log("source '{s}': no new documents", .{src.id});
    }
}

fn checkKeywordWatch(
    ctx: *Context,
    src: Source,
    prev: State,
    next_hashes: *std.ArrayList(State.KeywordHash),
) !void {
    const body = try httpGet(ctx, src.url);
    const context_blob = try extractKeywordContext(ctx.arena, body, src.match);

    const digest = std.hash.Wyhash.hash(0, context_blob);
    const hex = try std.fmt.allocPrint(ctx.arena, "{x:0>16}", .{digest});
    try next_hashes.append(ctx.arena, .{ .id = try ctx.arena.dupe(u8, src.id), .hash = hex });

    const old = prev.hashFor(src.id);
    if (old == null) {
        log("source '{s}': baseline recorded ({d} keyword bytes)", .{ src.id, context_blob.len });
        return;
    }
    if (std.mem.eql(u8, old.?, hex)) {
        log("source '{s}': unchanged", .{src.id});
        return;
    }

    try alert(ctx, try std.fmt.allocPrint(
        ctx.arena,
        "[CHANGED] {s}: keyword context shifted. Review {s}",
        .{ src.label, src.url },
    ), true);
}

/// Build a stable fingerprint of the keyword-relevant content on a page.
///
/// Raw HTML is far too volatile to hash directly (minified markup, rotating
/// session tokens, reordered blocks). So we: strip tags, collapse whitespace,
/// lowercase, then keep only a small context window around each keyword hit,
/// and finally sort + dedupe those windows. The result changes when the
/// substance near a watched keyword changes, and stays put otherwise.
fn extractKeywordContext(arena: Allocator, body: []const u8, kws: []const []const u8) ![]u8 {
    const text = try normalizeHtml(arena, body);

    const radius = 100;
    var windows: std.ArrayList([]const u8) = .empty;
    for (kws) |kw| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, text, start, kw)) |pos| {
            const lo = if (pos > radius) pos - radius else 0;
            const hi = @min(text.len, pos + kw.len + radius);
            try windows.append(arena, text[lo..hi]);
            start = pos + kw.len;
        }
    }

    std.mem.sort([]const u8, windows.items, {}, lessThanSlice);

    var out: std.ArrayList(u8) = .empty;
    var prev: ?[]const u8 = null;
    for (windows.items) |w| {
        if (prev) |p| {
            if (std.mem.eql(u8, p, w)) continue;
        }
        try out.append(arena, '\n');
        try out.appendSlice(arena, w);
        prev = w;
    }
    return out.items;
}

/// Strip HTML tags, lowercase, and collapse all whitespace runs to one space.
fn normalizeHtml(arena: Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    var last_space = true; // also trims leading whitespace
    for (body) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;

        if (std.ascii.isWhitespace(c)) {
            if (!last_space) {
                try out.append(arena, ' ');
                last_space = true;
            }
        } else {
            try out.append(arena, std.ascii.toLower(c));
            last_space = false;
        }
    }
    // Drop a single trailing separator so equivalent content hashes identically
    // regardless of trailing markup/whitespace.
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.items;
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

/// Fetch a URL with the system curl binary. Returns the response body (arena owned).
fn httpGet(ctx: *Context, url: []const u8) ![]u8 {
    const argv = [_][]const u8{
        "curl",                                "-sS",                        "-L",
        "--max-time",                          fetch_timeout_s,              "--fail",
        "-H",                                  "User-Agent: " ++ user_agent, "-H",
        "Accept: application/json, text/html", url,
    };
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &argv,
        .stdout_limit = .limited(16 * 1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                log("curl exit {d} for {s}: {s}", .{ code, url, std.mem.trim(u8, result.stderr, " \n\r") });
                return error.FetchFailed;
            }
        },
        else => return error.FetchFailed,
    }
    return result.stdout;
}

/// Verify the system curl binary can be spawned. Returns true only if
/// `curl --version` runs and exits 0.
fn curlAvailable(ctx: *Context) bool {
    const argv = [_][]const u8{ "curl", "--version" };
    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
    }) catch return false;
    switch (result.term) {
        .exited => |code| return code == 0,
        else => return false,
    }
}

fn loadState(ctx: *Context) !std.json.Parsed(State) {
    const data = try Io.Dir.cwd().readFileAlloc(
        ctx.io,
        ctx.state_path,
        ctx.arena,
        .limited(8 * 1024 * 1024),
    );
    return std.json.parseFromSlice(State, ctx.arena, data, .{ .ignore_unknown_fields = true });
}

fn saveState(ctx: *Context, state: State) !void {
    var file = try Io.Dir.cwd().createFile(ctx.io, ctx.state_path, .{});
    defer file.close(ctx.io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(ctx.io, &buf);
    try std.json.Stringify.value(state, .{ .whitespace = .indent_2 }, &fw.interface);
    try fw.interface.flush();
    log("state written to {s}", .{ctx.state_path});
}

/// Emit an alert to stdout, and optionally fire the notify hook for high-signal events.
fn alert(ctx: *Context, message: []const u8, high_signal: bool) !void {
    ctx.changed = true;
    var buf: [512]u8 = undefined;
    var fw = Io.File.stdout().writer(ctx.io, &buf);
    try fw.interface.writeAll(message);
    try fw.interface.writeAll("\n");
    try fw.interface.flush();

    if (high_signal) {
        if (ctx.notify_cmd) |cmd| runNotify(ctx, cmd, message);
    }
}

/// Run the user-supplied notify command via `sh -c`, with the alert message
/// available as the positional parameter $1 (avoids shell-injection and avoids
/// clobbering the child's environment).
/// Example:
///   export FABLE_MONITOR_NOTIFY='terminal-notifier -title fable -message "$1"'
fn runNotify(ctx: *Context, cmd: []const u8, message: []const u8) void {
    const argv = [_][]const u8{ "sh", "-c", cmd, "fable-monitor", message };
    _ = std.process.run(ctx.arena, ctx.io, .{ .argv = &argv }) catch |err| {
        log("notify hook failed: {s}", .{@errorName(err)});
    };
}

fn capTail(items: [][]const u8, max: usize) [][]const u8 {
    if (items.len <= max) return items;
    return items[items.len - max ..];
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[fable-monitor] " ++ fmt ++ "\n", args);
}

// ---------------------------------------------------------------------------
// Tests. Cover the pure logic that does the real work; the I/O paths (curl,
// state file, notify) are exercised end-to-end by running the binary.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "normalizeHtml strips tags, lowercases, collapses whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try normalizeHtml(arena, "  <p class=\"x\">Hello   FABLE</p>\n<b>World</b> ");
    try testing.expectEqualStrings("hello fable world", out);
}

test "containsAny matches and rejects" {
    const needles = [_][]const u8{ "fable", "mythos" };
    try testing.expect(containsAny("a fable here", &needles));
    try testing.expect(!containsAny("nothing relevant", &needles));
}

test "extractKeywordContext is stable under reordering and dedupes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const kws = [_][]const u8{"fable"};
    const a = try extractKeywordContext(arena, "<h1>fable status</h1>", &kws);
    const b = try extractKeywordContext(arena, "<div>fable status</div>", &kws);
    // Markup differs but the keyword context is identical → same fingerprint.
    try testing.expectEqualStrings(a, b);

    const none = try extractKeywordContext(arena, "<p>unrelated text</p>", &kws);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "capTail keeps only the most recent entries" {
    var items = [_][]const u8{ "1", "2", "3", "4", "5" };
    const tail = capTail(&items, 3);
    try testing.expectEqual(@as(usize, 3), tail.len);
    try testing.expectEqualStrings("3", tail[0]);
    try testing.expectEqualStrings("5", tail[2]);
    try testing.expectEqual(@as(usize, 2), capTail(items[0..2], 3).len);
}

test "State lookups" {
    const st = State{
        .federal_register_seen = @constCast(&[_][]const u8{ "2026-001", "2026-002" }),
        .keyword_hashes = @constCast(&[_]State.KeywordHash{
            .{ .id = "anthropic_news", .hash = "deadbeef" },
        }),
    };
    try testing.expect(st.hasSeen("2026-001"));
    try testing.expect(!st.hasSeen("2026-999"));
    try testing.expectEqualStrings("deadbeef", st.hashFor("anthropic_news").?);
    try testing.expect(st.hashFor("missing") == null);
}
