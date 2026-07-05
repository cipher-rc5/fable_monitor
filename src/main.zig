//! fable-monitor: watches official public sources for changes to the US
//! government export-control status of Anthropic's Fable 5 / Mythos 5 models,
//! and emits a verified, low-latency signal when access is restored.
//!
//! Design: one run = one poll. Sources are tiered by confidence and described
//! by a JSON config (an embedded default, overridable via FABLE_MONITOR_SOURCES).
//! Fetching is delegated to the system `curl` binary; compression to `zstd`;
//! everything else is std-only Zig. State persists to a small zstd-compressed
//! NDJSON file so each run can diff against the last and alert only on genuine
//! changes. The monitor's job ends at emitting the verified signal; any system
//! that acts on it lives in a separate process.
//!
//! This file is the CLI entrypoint: argument dispatch and environment wiring.
//! The poll itself lives in `poll.zig`; the concerns it drives live in sibling
//! modules (`config`, `sources`, `fetch`, `feed`, `html`, `state`, `events`,
//! `zstd`, `export`, `context`, `parquet`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const parquet = @import("parquet.zig");
const banner = @import("banner.zig");
const view = @import("view.zig");
const stats = @import("stats.zig");
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;
const fetch = @import("fetch.zig");
const events = @import("events.zig");
const export_mod = @import("export.zig");
const poll = @import("poll.zig");

const version = @import("build_options").version;

const usage =
    "Usage: fable-monitor [poll | preflight | audit | ack <event_id> | " ++
    "view [filters] | log [filters] | export [out_dir] | serve [port] | banner [text] [height]]";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const env = init.environ_map;

    const state_path: []const u8 = env.get("FABLE_MONITOR_STATE") orelse
        "fable_monitor_state.jsonl.zst";
    const log_path: []const u8 = env.get("FABLE_MONITOR_LOG") orelse
        "fable_monitor_events.jsonl.zst";
    const notify_cmd: ?[]const u8 = env.get("FABLE_MONITOR_NOTIFY");

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

    const stats_on = env.get("FABLE_MONITOR_STATS") != null;
    defer if (stats_on) stats.report();

    const opts = poll.Options{
        .sources_path = env.get("FABLE_MONITOR_SOURCES"),
        .only_csv = env.get("FABLE_MONITOR_ONLY"),
        .disable_csv = env.get("FABLE_MONITOR_DISABLE"),
        .fixtures_dir = env.get("FABLE_MONITOR_FIXTURES"),
        .force_all = env.get("FABLE_MONITOR_FORCE") != null,
        .fast_interval_override = envU32(env, "FABLE_MONITOR_FAST_INTERVAL"),
        .event_sink_path = env.get("FABLE_MONITOR_EVENT_SINK"),
        .webhook_url = env.get("FABLE_MONITOR_WEBHOOK"),
        .heartbeat_url = env.get("FABLE_MONITOR_HEARTBEAT_URL"),
        .escalate_after_s = envU32(env, "FABLE_MONITOR_ESCALATE_AFTER") orelse 3600,
        .log_metrics = stats_on or env.get("FABLE_MONITOR_METRICS") != null,
        .anthropic_api_key = env.get("ANTHROPIC_API_KEY"),
    };

    const argv = try init.minimal.args.toSlice(arena);

    // `banner` is self-contained (no files, network, or compression), so it is
    // handled before the zstd/curl preflights.
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "banner")) {
        const text = if (argv.len > 2) argv[2] else "FABLE";
        const height = if (argv.len > 3) (std.fmt.parseInt(usize, argv[3], 10) catch 0) else 0;
        return banner.render(io, arena, text, height);
    }

    // Both poll and export read/write zstd-compressed files, so the `zstd`
    // binary is required (see design-decisions.md).
    if (!fetch.toolAvailable(&ctx, "zstd")) {
        fatal("fatal: `zstd` not found on PATH; fable-monitor compresses its outputs with it. Install it or add it to PATH.", .{});
    }

    if (argv.len > 1) {
        const cmd = argv[1];
        if (std.mem.eql(u8, cmd, "export")) {
            const out_dir = if (argv.len > 2) argv[2] else "parquet";
            return export_mod.exportParquet(&ctx, out_dir);
        }
        if (std.mem.eql(u8, cmd, "log")) {
            return view.run(io, arena, log_path, argv[2..], .log, now.toSeconds());
        }
        if (std.mem.eql(u8, cmd, "view")) {
            return view.run(io, arena, log_path, argv[2..], .view, now.toSeconds());
        }
        if (std.mem.eql(u8, cmd, "audit")) {
            return poll.audit(&ctx, opts);
        }
        if (std.mem.eql(u8, cmd, "ack")) {
            if (argv.len < 3) {
                fatal("usage: fable-monitor ack <event_id>", .{});
            }
            return poll.acknowledge(&ctx, argv[2]);
        }
        if (std.mem.eql(u8, cmd, "serve")) {
            const serve = @import("serve.zig");
            const port: u16 = blk: {
                if (argv.len > 2) break :blk std.fmt.parseInt(u16, argv[2], 10) catch serve.default_port;
                if (env.get("FABLE_MONITOR_PORT")) |p| break :blk std.fmt.parseInt(u16, p, 10) catch serve.default_port;
                break :blk serve.default_port;
            };
            return serve.run(&ctx, .{
                .sources_path = opts.sources_path,
                .only_csv = opts.only_csv,
                .disable_csv = opts.disable_csv,
            }, port);
        }
        if (std.mem.eql(u8, cmd, "preflight")) {
            // curl is required for egress checks.
            if (!fetch.toolAvailable(&ctx, "curl")) {
                fatal("fatal: `curl` not found on PATH.", .{});
            }
            // A failed preflight must be visible to supervisors, not just in
            // the log (preflight logs its own findings before erroring).
            poll.preflight(&ctx, opts) catch |err| fatal("preflight failed: {s}", .{@errorName(err)});
            return;
        }
        if (!std.mem.eql(u8, cmd, "poll")) {
            fatal("unknown command '{s}'. {s}", .{ cmd, usage });
        }
        // "poll" falls through to the default below.
    }

    // Default: poll. Fetching is delegated to system curl; bail early with a
    // clear message rather than letting every source fail with a spawn error.
    if (!fetch.toolAvailable(&ctx, "curl")) {
        fatal("fatal: `curl` not found on PATH; fable-monitor requires the system curl binary. Install it or add it to PATH.", .{});
    }

    log("fable-monitor {s}", .{version});

    // Optional internal loop for environments without a sub-minute scheduler.
    // FABLE_MONITOR_LOOP=<seconds> runs the poll repeatedly, sleeping between
    // ticks; due-based cadence inside the poll still gates per-tier work.
    if (envU32(env, "FABLE_MONITOR_LOOP")) |period_s| {
        log("loop mode: polling every {d}s (Ctrl-C to stop)", .{period_s});
        while (true) {
            // A failed poll iteration is expected weather (network blips);
            // keep looping. A failed sleep is not: the loop would hot-spin,
            // so treat it as unrecoverable and let the supervisor restart us.
            poll.run(&ctx, opts) catch |err| log("poll error: {s}", .{@errorName(err)});
            Io.sleep(io, Io.Duration.fromSeconds(@intCast(period_s)), .awake) catch |err| {
                fatal("fatal: loop sleep failed ({s}); exiting", .{@errorName(err)});
            };
        }
    }

    try poll.run(&ctx, opts);
}

/// Log a fatal message and exit nonzero. Fatal startup paths must not return
/// cleanly: launchd/systemd/cron read a zero exit as success, so a log-then-
/// return would make a dead monitor look healthy.
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log(fmt, args);
    std.process.exit(1);
}

/// Parse an optional unsigned-integer environment variable, ignoring a malformed
/// value (treated as unset).
fn envU32(env: anytype, key: []const u8) ?u32 {
    const v = env.get(key) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
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
    _ = stats;
    _ = @import("html.zig");
    _ = @import("state.zig");
    _ = @import("events.zig");
    _ = @import("zstd.zig");
    _ = @import("sources.zig");
    _ = @import("config.zig");
    _ = @import("fetch.zig");
    _ = @import("feed.zig");
    _ = @import("poll.zig");
    _ = @import("export.zig");
    _ = @import("context.zig");
    _ = @import("serve.zig");
}
