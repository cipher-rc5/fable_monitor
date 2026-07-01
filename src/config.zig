//! Runtime source configuration. Sources are described by a JSON document so
//! they can be toggled or edited without rebuilding. A default config is
//! embedded in the binary (so the monitor works out of the box); pointing
//! FABLE_MONITOR_SOURCES at a file replaces it. Per-source enable flags can be
//! overridden from the environment (FABLE_MONITOR_ONLY / FABLE_MONITOR_DISABLE)
//! so an operator can narrow coverage without editing the file.
//!
//! Parsing is lenient (unknown fields ignored, sensible defaults) and fails
//! closed per source: a malformed source entry is skipped with a warning rather
//! than aborting the load.

const std = @import("std");
const Allocator = std.mem.Allocator;
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;
const sources_mod = @import("sources.zig");
const Source = sources_mod.Source;
const Tier = sources_mod.Tier;
const SourceKind = sources_mod.SourceKind;
const PollClass = sources_mod.PollClass;

/// The default config, compiled into the binary. Editing it requires a rebuild;
/// for ad-hoc changes set FABLE_MONITOR_SOURCES to an external JSON file.
const default_json = @embedFile("sources_default.json");

/// Resolved runtime configuration: the cadence parameters plus the active
/// source list (after applying enable/disable overrides).
pub const Config = struct {
    version: u32 = 1,
    fast_interval_s: u32 = 45,
    slow_interval_s: u32 = 1800,
    concurrency: u32 = 1,
    sources: []Source = &.{},
    /// Where the config came from, for the startup log line.
    origin: []const u8 = "embedded default",
};

// --- JSON shapes (parsed leniently, then converted) -------------------------

const RawConfig = struct {
    version: u32 = 1,
    fast_interval_s: u32 = 45,
    slow_interval_s: u32 = 1800,
    concurrency: u32 = 1,
    sources: []RawSource = &.{},
};

const RawSource = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    tier: u8 = 3,
    label: []const u8 = "",
    url: []const u8 = "",
    match: []const []const u8 = &.{},
    enabled: bool = true,
    poll: []const u8 = "",
    lead_time: []const u8 = "",
};

/// Options the loader needs from the environment.
pub const LoadOptions = struct {
    /// External JSON path (FABLE_MONITOR_SOURCES); null uses the embedded default.
    sources_path: ?[]const u8 = null,
    /// Comma-separated source ids; if set, ONLY these are enabled.
    only_csv: ?[]const u8 = null,
    /// Comma-separated source ids to force-disable.
    disable_csv: ?[]const u8 = null,
};

/// Load and resolve the configuration. Never fails: an unreadable or malformed
/// external file falls back to the embedded default with a warning, so the
/// monitor always has sources to poll.
pub fn load(ctx: *Context, opts: LoadOptions) Config {
    var origin: []const u8 = "embedded default";
    const json: []const u8 = blk: {
        if (opts.sources_path) |path| {
            if (std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(8 * 1024 * 1024)) catch null) |bytes| {
                origin = path;
                break :blk bytes;
            }
            log("warning: could not read sources config '{s}'; using embedded default", .{path});
        }
        break :blk default_json;
    };

    const raw = std.json.parseFromSliceLeaky(RawConfig, ctx.arena, json, .{ .ignore_unknown_fields = true }) catch |err| {
        log("warning: sources config parse failed ({s}); using embedded default", .{@errorName(err)});
        return loadDefault(ctx, opts);
    };

    return resolve(ctx, raw, origin, opts);
}

fn loadDefault(ctx: *Context, opts: LoadOptions) Config {
    const raw = std.json.parseFromSliceLeaky(RawConfig, ctx.arena, default_json, .{ .ignore_unknown_fields = true }) catch {
        return .{}; // unreachable in practice: the embedded default is valid JSON
    };
    return resolve(ctx, raw, "embedded default", opts);
}

fn resolve(ctx: *Context, raw: RawConfig, origin: []const u8, opts: LoadOptions) Config {
    var list: std.ArrayList(Source) = .empty;
    for (raw.sources) |rs| {
        const kind = SourceKind.fromString(rs.kind) orelse {
            log("warning: source '{s}' has unknown kind '{s}'; skipping", .{ rs.id, rs.kind });
            continue;
        };
        if (rs.id.len == 0 or rs.url.len == 0) {
            log("warning: source with kind '{s}' missing id or url; skipping", .{rs.kind});
            continue;
        }
        const tier = Tier.fromInt(rs.tier);
        const enabled = resolveEnabled(rs.id, rs.enabled, opts);
        const src = Source{
            .id = rs.id,
            .kind = kind,
            .tier = tier,
            .url = rs.url,
            .label = if (rs.label.len > 0) rs.label else rs.id,
            .match = defaultMatch(rs.match, kind),
            .enabled = enabled,
            .poll = resolvePoll(rs.poll, tier),
            .lead_time = rs.lead_time,
        };
        list.append(ctx.arena, src) catch return .{};
    }

    return .{
        .version = raw.version,
        .fast_interval_s = raw.fast_interval_s,
        .slow_interval_s = raw.slow_interval_s,
        .concurrency = if (raw.concurrency == 0) 1 else raw.concurrency,
        .sources = list.items,
        .origin = origin,
    };
}

/// A source's match set defaults to a kind-appropriate vocabulary when the
/// config leaves it empty.
fn defaultMatch(match: []const []const u8, kind: SourceKind) []const []const u8 {
    if (match.len > 0) return match;
    return switch (kind) {
        .model_list_probe, .api_probe => &sources_mod.model_ids,
        .statement_watch => &sources_mod.restoration_terms,
        else => &sources_mod.keywords,
    };
}

fn resolvePoll(poll: []const u8, tier: Tier) PollClass {
    if (std.mem.eql(u8, poll, "fast")) return .fast;
    if (std.mem.eql(u8, poll, "slow")) return .slow;
    return if (tier == .tier1) .fast else .slow;
}

/// Apply the environment enable/disable overrides. ONLY wins: if it is set, a
/// source must be listed there to be enabled. DISABLE then force-disables.
fn resolveEnabled(id: []const u8, config_enabled: bool, opts: LoadOptions) bool {
    var enabled = config_enabled;
    if (opts.only_csv) |csv| enabled = csvContains(csv, id);
    if (opts.disable_csv) |csv| {
        if (csvContains(csv, id)) enabled = false;
    }
    return enabled;
}

/// True if `id` appears as a comma-separated token in `csv` (trimmed).
pub fn csvContains(csv: []const u8, id: []const u8) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, std.mem.trim(u8, tok, " \t"), id)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "csvContains matches trimmed tokens" {
    try testing.expect(csvContains("a, b ,c", "b"));
    try testing.expect(csvContains("fr_bis,fr_anthropic", "fr_anthropic"));
    try testing.expect(!csvContains("a,b,c", "d"));
    try testing.expect(!csvContains("", "a"));
}

test "defaultMatch picks a vocabulary by kind when empty" {
    try testing.expectEqual(@as(usize, sources_mod.model_ids.len), defaultMatch(&.{}, .model_list_probe).len);
    try testing.expectEqual(@as(usize, sources_mod.model_ids.len), defaultMatch(&.{}, .api_probe).len);
    try testing.expectEqual(@as(usize, sources_mod.restoration_terms.len), defaultMatch(&.{}, .statement_watch).len);
    try testing.expectEqual(@as(usize, sources_mod.keywords.len), defaultMatch(&.{}, .federal_register).len);
    const custom = [_][]const u8{"x"};
    try testing.expectEqual(@as(usize, 1), defaultMatch(&custom, .model_list_probe).len);
}

test "resolvePoll defaults by tier and honors overrides" {
    try testing.expectEqual(PollClass.fast, resolvePoll("", .tier1));
    try testing.expectEqual(PollClass.slow, resolvePoll("", .tier2));
    try testing.expectEqual(PollClass.fast, resolvePoll("fast", .tier3));
    try testing.expectEqual(PollClass.slow, resolvePoll("slow", .tier1));
}

test "resolveEnabled applies ONLY then DISABLE" {
    try testing.expect(resolveEnabled("a", true, .{}));
    try testing.expect(!resolveEnabled("a", true, .{ .only_csv = "b,c" }));
    try testing.expect(resolveEnabled("a", true, .{ .only_csv = "a,c" }));
    try testing.expect(!resolveEnabled("a", true, .{ .disable_csv = "a" }));
    try testing.expect(!resolveEnabled("a", false, .{})); // config wins when no override
}

test "default config parses and yields the expected source kinds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const raw = try std.json.parseFromSliceLeaky(RawConfig, arena_state.allocator(), default_json, .{ .ignore_unknown_fields = true });
    try testing.expect(raw.sources.len >= 8);
    // At least three independent tier-1 detectors must exist (no single point of
    // failure in the decisive signal path), and a statement watcher among them.
    var tier1: usize = 0;
    var has_statement = false;
    var has_model_probe = false;
    for (raw.sources) |s| {
        if (s.tier == 1) tier1 += 1;
        if (std.mem.eql(u8, s.kind, "statement_watch")) has_statement = true;
        if (std.mem.eql(u8, s.kind, "model_list_probe")) has_model_probe = true;
    }
    try testing.expect(tier1 >= 3);
    try testing.expect(has_statement);
    try testing.expect(has_model_probe);
}
