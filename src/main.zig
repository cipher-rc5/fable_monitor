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
const state = @import("state.zig");

const version = @import("build_options").version;

const usage =
    "Usage: fable-monitor [poll | preflight [--json] | audit | ack <event_id> | delivery [list|retry [id]] | state [inspect|recover|rebaseline] | " ++
    "view [filters] | log [filters] | log compact [max_events] | log recover | export [out_dir] | serve [port] | banner [text] [height]]";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const env = init.environ_map;
    // The reader reads this value in the serving module; validate it alongside
    // the other booleans so typos fail at startup instead of silently disabling it.
    _ = envBool(env, "FABLE_MONITOR_READER");

    const state_path: []const u8 = optionalEnv(env, "FABLE_MONITOR_STATE") orelse
        "fable_monitor_state.jsonl.zst";
    const log_path: []const u8 = optionalEnv(env, "FABLE_MONITOR_LOG") orelse
        "fable_monitor_events.jsonl.zst";
    const notify_cmd = optionalEnv(env, "FABLE_MONITOR_NOTIFY");

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

    const stats_on = envBool(env, "FABLE_MONITOR_STATS") orelse false;
    defer if (stats_on) stats.report();

    const required_sources = parseRequiredSources(arena, optionalEnv(env, "FABLE_MONITOR_REQUIRED_SOURCES")) catch |err|
        fatal("fatal: FABLE_MONITOR_REQUIRED_SOURCES is invalid ({s})", .{@errorName(err)});
    const opts = poll.Options{
        .sources_path = optionalEnv(env, "FABLE_MONITOR_SOURCES"),
        .only_csv = optionalEnv(env, "FABLE_MONITOR_ONLY"),
        .disable_csv = optionalEnv(env, "FABLE_MONITOR_DISABLE"),
        .fixtures_dir = optionalEnv(env, "FABLE_MONITOR_FIXTURES"),
        .force_all = envBool(env, "FABLE_MONITOR_FORCE") orelse false,
        .fast_interval_override = envPositiveU32(env, "FABLE_MONITOR_FAST_INTERVAL"),
        .event_sink_path = optionalEnv(env, "FABLE_MONITOR_EVENT_SINK"),
        .webhook_url = optionalEnv(env, "FABLE_MONITOR_WEBHOOK"),
        .heartbeat_url = optionalEnv(env, "FABLE_MONITOR_HEARTBEAT_URL"),
        .escalate_after_s = envU32(env, "FABLE_MONITOR_ESCALATE_AFTER") orelse 3600,
        .log_metrics = stats_on or (envBool(env, "FABLE_MONITOR_METRICS") orelse false),
        .max_events = envPositiveUsize(env, "FABLE_MONITOR_MAX_EVENTS") orelse 100_000,
        .anthropic_api_key = optionalEnv(env, "ANTHROPIC_API_KEY"),
        .required_source_ids = required_sources,
        .minimum_decisive_sources = envPositiveU32(env, "FABLE_MONITOR_MIN_DECISIVE_SOURCES") orelse 1,
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
            if (argv.len > 2 and std.mem.eql(u8, argv[2], "recover"))
                return events.recoverManifest(io, arena, log_path);
            if (argv.len > 2 and std.mem.eql(u8, argv[2], "compact")) {
                const max_events = if (argv.len > 3)
                    (std.fmt.parseInt(usize, argv[3], 10) catch fatal("fatal: max_events must be a positive integer", .{}))
                else
                    opts.max_events;
                if (max_events == 0) fatal("fatal: max_events must be a positive integer", .{});
                return events.compactLog(io, arena, log_path, max_events);
            }
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
        if (std.mem.eql(u8, cmd, "delivery")) {
            const action = if (argv.len > 2) argv[2] else "list";
            if (std.mem.eql(u8, action, "list")) return poll.inspectDeliveries(&ctx);
            if (std.mem.eql(u8, action, "retry")) {
                const wanted: ?[]const u8 = if (argv.len > 3) argv[3] else null;
                return poll.deliverPending(&ctx, opts, true, wanted);
            }
            fatal("usage: fable-monitor delivery [list | retry [event_id|occurrence_id]]", .{});
        }
        if (std.mem.eql(u8, cmd, "state")) {
            const action = if (argv.len > 2) argv[2] else "inspect";
            if (std.mem.eql(u8, action, "inspect")) {
                const inspection = try state.inspectState(&ctx);
                const encoded = try std.json.Stringify.valueAlloc(arena, inspection, .{});
                return writeStdout(io, encoded);
            }
            var lock = try state.acquireLock(&ctx);
            defer lock.release(io);
            if (std.mem.eql(u8, action, "recover")) {
                const result = try state.recoverState(&ctx);
                const encoded = try std.json.Stringify.valueAlloc(arena, result, .{});
                return writeStdout(io, encoded);
            }
            if (std.mem.eql(u8, action, "rebaseline")) {
                const result = try state.rebaselineState(&ctx);
                const encoded = try std.json.Stringify.valueAlloc(arena, result, .{});
                return writeStdout(io, encoded);
            }
            fatal("usage: fable-monitor state [inspect | recover | rebaseline]", .{});
        }
        if (std.mem.eql(u8, cmd, "serve")) {
            const serve = @import("serve.zig");
            const port: u16 = blk: {
                if (argv.len > 2) break :blk parsePort("command line", argv[2]);
                if (optionalEnv(env, "FABLE_MONITOR_PORT")) |p| break :blk parsePort("FABLE_MONITOR_PORT", p);
                break :blk serve.default_port;
            };
            return serve.run(&ctx, .{
                .sources_path = opts.sources_path,
                .only_csv = opts.only_csv,
                .disable_csv = opts.disable_csv,
                .required_source_ids = opts.required_source_ids,
                .minimum_decisive_sources = opts.minimum_decisive_sources,
                .fast_interval_override = opts.fast_interval_override,
            }, port);
        }
        if (std.mem.eql(u8, cmd, "preflight")) {
            // curl is required for egress checks.
            if (!fetch.toolAvailable(&ctx, "curl")) {
                fatal("fatal: `curl` not found on PATH.", .{});
            }
            if (argv.len > 2 and std.mem.eql(u8, argv[2], "--json")) {
                const result = try poll.preflightResult(&ctx, opts);
                const encoded = try poll.preflightJson(arena, result);
                try writeStdout(io, encoded);
                if (!result.ok) std.process.exit(1);
                return;
            }
            if (argv.len > 2) fatal("usage: fable-monitor preflight [--json]", .{});
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
    //
    // Loop mode must NOT reuse the startup `ctx`: every poll allocates from
    // `ctx.arena` (fetched bodies, decompressed state, JSON, formatted strings)
    // and appends to `ctx.events`, and one-shot mode relies on process exit to
    // reclaim all of it. Reusing one process-lifetime arena across ticks would
    // grow memory without bound until the host is starved. Instead each tick
    // gets a fresh arena that is reset afterward, a fresh (empty) event list,
    // and a freshly stamped poll time. `.retain_capacity` keeps the backing
    // buffer so steady-state memory settles at one poll's high-water mark
    // rather than thrashing the allocator. Nothing needs to survive between
    // ticks: the poll reloads prior state from disk every cycle.
    if (envPositiveU32(env, "FABLE_MONITOR_LOOP")) |period_s| {
        const max_failures = envPositiveU32(env, "FABLE_MONITOR_LOOP_MAX_FAILURES") orelse 3;
        log("loop mode: polling every {d}s; exiting after {d} consecutive failures", .{ period_s, max_failures });
        var tick_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tick_arena.deinit();
        var consecutive_failures: u32 = 0;
        while (true) {
            const tick_a = tick_arena.allocator();
            const tick_now = Io.Timestamp.now(io, .real);
            var tick_ctx = Context{
                .io = io,
                .arena = tick_a,
                .state_path = state_path,
                .log_path = log_path,
                .notify_cmd = notify_cmd,
                .observed_at = events.isoUtc(tick_a, tick_now.toSeconds()) catch |err|
                    fatal("fatal: timestamp format failed ({s}); exiting", .{@errorName(err)}),
                .epoch_ms = tick_now.toMilliseconds(),
            };
            if (poll.run(&tick_ctx, opts)) |_| {
                consecutive_failures = 0;
            } else |err| {
                consecutive_failures += 1;
                log("poll error: {s} ({d}/{d} consecutive failures)", .{ @errorName(err), consecutive_failures, max_failures });
                if (consecutive_failures >= max_failures)
                    fatal("fatal: loop reached consecutive failure limit; exiting", .{});
            }
            _ = tick_arena.reset(.retain_capacity);
            Io.sleep(io, Io.Duration.fromSeconds(@intCast(period_s)), .awake) catch |err| {
                fatal("fatal: loop sleep failed ({s}); exiting", .{@errorName(err)});
            };
        }
    }

    // Single-shot poll. `poll.run` already logs the outcome (and any lock,
    // persistence, or delivery diagnostic) before returning; map its failure to
    // a clean nonzero exit so a scheduler sees the failure without a raw error
    // return trace that a zero-exit reader would ignore anyway.
    poll.run(&ctx, opts) catch |err| {
        if (err == error.OutOfMemory) return err;
        fatal("poll failed: {s}", .{@errorName(err)});
    };
}

fn writeStdout(io: Io, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

/// Log a fatal message and exit nonzero. Fatal startup paths must not return
/// cleanly: launchd/systemd/cron read a zero exit as success, so a log-then-
/// return would make a dead monitor look healthy.
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log(fmt, args);
    std.process.exit(1);
}

/// Parse an optional unsigned-integer environment variable. A value that is
/// present but malformed is a deployment error, not an implicit default.
fn envU32(env: anytype, key: []const u8) ?u32 {
    const v = optionalEnv(env, key) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch fatal("fatal: {s} must be an unsigned integer", .{key});
}

fn envPositiveU32(env: anytype, key: []const u8) ?u32 {
    const value = envU32(env, key) orelse return null;
    if (value == 0) fatal("fatal: {s} must be greater than zero", .{key});
    return value;
}

fn envPositiveUsize(env: anytype, key: []const u8) ?usize {
    const v = optionalEnv(env, key) orelse return null;
    const value = std.fmt.parseInt(usize, v, 10) catch fatal("fatal: {s} must be a positive integer", .{key});
    if (value == 0) fatal("fatal: {s} must be greater than zero", .{key});
    return value;
}

fn optionalEnv(env: anytype, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

/// Boolean environment variables use 1/0. Empty is equivalent to unset, while
/// every other value is rejected so misspelled deployment settings cannot
/// silently enable or disable behavior.
fn envBool(env: anytype, key: []const u8) ?bool {
    const value = optionalEnv(env, key) orelse return null;
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "0")) return false;
    fatal("fatal: {s} must be 1 or 0", .{key});
}

const RequiredSourcesError = error{ EmptySourceId, DuplicateSourceId };

fn parseRequiredSources(arena: Allocator, value: ?[]const u8) (Allocator.Error || RequiredSourcesError)![]const []const u8 {
    const csv = value orelse return &.{};
    if (csv.len == 0) return error.EmptySourceId;
    var ids: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const id = std.mem.trim(u8, raw, " \t");
        if (id.len == 0) return error.EmptySourceId;
        for (ids.items) |prior| if (std.mem.eql(u8, prior, id)) return error.DuplicateSourceId;
        try ids.append(arena, id);
    }
    return ids.items;
}

fn parsePort(origin: []const u8, value: []const u8) u16 {
    const port = std.fmt.parseInt(u16, value, 10) catch
        fatal("fatal: {s} must be a port in the range 1..65535", .{origin});
    if (port == 0) fatal("fatal: {s} must be a port in the range 1..65535", .{origin});
    return port;
}

test "numeric parsing accepts valid values" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("NUMBER", "42");
    try std.testing.expectEqual(@as(?u32, 42), envU32(&env, "NUMBER"));
    try std.testing.expectEqual(@as(u16, 8080), parsePort("test", "8080"));
}

test "empty optional environment values are unset" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("EMPTY", "");
    try env.put("FALSE", "0");
    try env.put("TRUE", "1");
    try std.testing.expectEqual(@as(?[]const u8, null), optionalEnv(&env, "EMPTY"));
    try std.testing.expectEqual(@as(?u32, null), envU32(&env, "EMPTY"));
    try std.testing.expectEqual(@as(?bool, null), envBool(&env, "EMPTY"));
    try std.testing.expectEqual(@as(?bool, false), envBool(&env, "FALSE"));
    try std.testing.expectEqual(@as(?bool, true), envBool(&env, "TRUE"));
}

test "required source parsing is strict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ids = try parseRequiredSources(arena, " alpha, beta ");
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("alpha", ids[0]);
    try std.testing.expectError(error.EmptySourceId, parseRequiredSources(arena, "alpha,"));
    try std.testing.expectError(error.DuplicateSourceId, parseRequiredSources(arena, "alpha,alpha"));
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
