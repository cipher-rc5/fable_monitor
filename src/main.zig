//! fable-monitor: watches official sources for changes to the US government
//! export-control status of Anthropic's Fable 5 / Mythos 5 models.
//!
//! Design: one run = one poll. Intended to be driven by launchd or cron.
//! Fetching is delegated to the system `curl` binary (ubiquitous, handles TLS),
//! everything else is std-only Zig. State persists to a small JSON file so each
//! run can diff against the last and only alert on genuine changes.
//!
//! This file is the CLI entrypoint: argument dispatch and the poll
//! orchestration loop. The concerns it drives live in sibling modules
//! (`sources`, `fetch`, `html`, `state`, `events`, `zstd`, `export`,
//! `context`, `parquet`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const parquet = @import("parquet.zig");
const banner = @import("banner.zig");
const view = @import("view.zig");
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;
const sources_mod = @import("sources.zig");
const Source = sources_mod.Source;
const sources = sources_mod.sources;
const fetch = @import("fetch.zig");
const html = @import("html.zig");
const state_mod = @import("state.zig");
const State = state_mod.State;
const events = @import("events.zig");
const export_mod = @import("export.zig");

const version = @import("build_options").version;

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const state_path: []const u8 = init.environ_map.get("FABLE_MONITOR_STATE") orelse
        "fable_monitor_state.jsonl.zst";
    const log_path: []const u8 = init.environ_map.get("FABLE_MONITOR_LOG") orelse
        "fable_monitor_events.jsonl.zst";
    const notify_cmd: ?[]const u8 = init.environ_map.get("FABLE_MONITOR_NOTIFY");

    const now = Io.Timestamp.now(io, .real);
    var ctx = Context{
        .io = io,
        .arena = arena,
        .state_path = state_path,
        .log_path = log_path,
        .notify_cmd = notify_cmd,
        .observed_at = try events.isoUtc(arena, now.toSeconds()),
        .epoch_ms = now.toMilliseconds(),
    };

    // Argument vector: argv[0] is the program name; argv[1] is an optional
    // subcommand. With no subcommand we poll (the default behavior).
    const argv = try init.minimal.args.toSlice(arena);

    // `banner` is self-contained (no files, no network, no compression), so it
    // is handled before the zstd/curl preflights.
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "banner")) {
        const text = if (argv.len > 2) argv[2] else "FABLE";
        const height = if (argv.len > 3) (std.fmt.parseInt(usize, argv[3], 10) catch 0) else 0;
        return banner.render(io, arena, text, height);
    }

    // Both poll and export read/write zstd-compressed files, so the `zstd`
    // binary is required in either mode (see design-decisions.md).
    if (!fetch.toolAvailable(&ctx, "zstd")) {
        log("fatal: `zstd` not found on PATH; fable-monitor compresses its outputs with it. Install it or add it to PATH.", .{});
        return;
    }

    if (argv.len > 1) {
        const cmd = argv[1];
        if (std.mem.eql(u8, cmd, "export")) {
            const out_dir = if (argv.len > 2) argv[2] else "parquet";
            return export_mod.exportParquet(&ctx, out_dir);
        }
        if (std.mem.eql(u8, cmd, "log")) {
            return view.run(io, arena, log_path, argv[2..]);
        }
        if (std.mem.eql(u8, cmd, "poll")) {
            // explicit alias for the default; fall through
        } else {
            log("unknown command '{s}'. Usage: fable-monitor [poll | log [filters] | export [out_dir] | banner [text] [height]]", .{cmd});
            return;
        }
    }

    log("fable-monitor {s} polling {d} sources", .{ version, sources.len });

    // Fetching is delegated to system curl; bail early with a clear message
    // rather than letting every source fail with an opaque spawn error.
    if (!fetch.toolAvailable(&ctx, "curl")) {
        log("fatal: `curl` not found on PATH; fable-monitor requires the system curl binary. Install it or add it to PATH.", .{});
        return;
    }

    // Load previous state (empty on first run / missing file).
    const prev: State = state_mod.loadState(&ctx) catch |err| blk: {
        log("warning: could not read state ({s}); starting fresh", .{@errorName(err)});
        break :blk .{};
    };

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
        .federal_register_seen = state_mod.capTail(next_seen.items, 200),
        .keyword_hashes = next_hashes.items,
    };
    state_mod.saveState(&ctx, next) catch |err| {
        log("error: failed to persist state: {s}", .{@errorName(err)});
    };

    // Append this run's observations to the history log (a no-op when nothing
    // new was seen). Failure to log must not fail the poll.
    events.appendLog(ctx.io, ctx.arena, ctx.log_path, ctx.events.items) catch |err| {
        log("error: failed to append observation log: {s}", .{@errorName(err)});
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
    const body = try fetch.httpGet(ctx, src.url);
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
        const relevant = html.containsAny(haystack, src.match);
        const tag = if (relevant) "RELEVANT" else "new";
        try alert(ctx, try std.fmt.allocPrint(
            ctx.arena,
            "[{s}] Federal Register {s} doc {s} ({s}): {s}\n  {s}",
            .{ tag, src.label, doc.document_number, doc.publication_date, doc.title, doc.html_url },
        ), relevant);

        try ctx.record(.{
            .source_id = src.id,
            .source_label = src.label,
            .source_kind = "federal_register",
            .event = if (relevant) events.ev_relevant_document else events.ev_new_document,
            .document_number = doc.document_number,
            .title = doc.title,
            .publication_date = doc.publication_date,
            .url = doc.html_url,
        });
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
    const body = try fetch.httpGet(ctx, src.url);
    const context_blob = try html.extractKeywordContext(ctx.arena, body, src.match);

    const digest = std.hash.Wyhash.hash(0, context_blob);
    const hex = try std.fmt.allocPrint(ctx.arena, "{x:0>16}", .{digest});
    try next_hashes.append(ctx.arena, .{ .id = try ctx.arena.dupe(u8, src.id), .hash = hex });

    const old = prev.hashFor(src.id);
    if (old == null) {
        log("source '{s}': baseline recorded ({d} keyword bytes)", .{ src.id, context_blob.len });
        try ctx.record(.{
            .source_id = src.id,
            .source_label = src.label,
            .source_kind = "keyword_watch",
            .event = events.ev_baseline,
            .url = src.url,
            .detail = hex,
        });
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

    try ctx.record(.{
        .source_id = src.id,
        .source_label = src.label,
        .source_kind = "keyword_watch",
        .event = events.ev_changed,
        .url = src.url,
        .detail = hex,
    });
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

// ---------------------------------------------------------------------------
// Test root. Tests live next to the code they cover; this block references
// every module so `zig build test` runs all of them (tests in an imported file
// only run if that file is reachable from the test root).
// ---------------------------------------------------------------------------

test {
    _ = parquet;
    _ = banner;
    _ = view;
    _ = @import("html.zig");
    _ = @import("state.zig");
    _ = @import("events.zig");
    _ = @import("zstd.zig");
    _ = @import("sources.zig");
    _ = @import("fetch.zig");
    _ = @import("export.zig");
    _ = @import("context.zig");
}
