//! Runtime source configuration. Sources are described by a JSON document so
//! they can be toggled or edited without rebuilding. A default config is
//! embedded in the binary (so the monitor works out of the box); pointing
//! FABLE_MONITOR_SOURCES at a file replaces it. Per-source enable flags can be
//! overridden from the environment (FABLE_MONITOR_ONLY / FABLE_MONITOR_DISABLE)
//! so an operator can narrow coverage without editing the file.
//!
//! Configuration is validated as a unit. An explicitly selected file must be
//! readable and valid; silently falling back would hide deployment mistakes.

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
    sources: []Source = &.{},
    /// Where the config came from, for the startup log line.
    origin: []const u8 = "embedded default",
};

// --- JSON shapes ------------------------------------------------------------

const RawConfig = struct {
    version: u32 = 0,
    fast_interval_s: u32 = 45,
    slow_interval_s: u32 = 1800,
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
    /// Decisive source ids that must remain fresh for health/readiness.
    required_source_ids: []const []const u8 = &.{},
    /// Minimum number of enabled decisive sources that must remain fresh.
    minimum_decisive_sources: u32 = 1,
    /// Optional runtime cadence override, used by readiness freshness checks.
    fast_interval_override: ?u32 = null,
};

const ValidationError = error{
    UnsupportedVersion,
    InvalidInterval,
    InvalidSource,
    InvalidSourceUrl,
    InvalidSourceSchema,
    DuplicateSourceId,
    UnknownSourceOverride,
    InvalidRequiredSource,
    DuplicateRequiredSource,
    InvalidMinimumDecisiveSources,
    NoEnabledSources,
};

/// Load and resolve the configuration. Startup configuration errors are fatal
/// because a fallback could run a materially different monitor than requested.
pub fn load(ctx: *Context, opts: LoadOptions) Config {
    return loadChecked(ctx, opts) catch |err| fatalConfig(opts.sources_path orelse "embedded default", err);
}

/// Recoverable loader for preflight and automation. JSON object fields are
/// strict: misspelled top-level or source fields are rejected by the decoder.
pub fn loadChecked(ctx: *Context, opts: LoadOptions) !Config {
    var origin: []const u8 = "embedded default";
    const json: []const u8 = blk: {
        if (opts.sources_path) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(8 * 1024 * 1024));
            origin = path;
            break :blk bytes;
        }
        break :blk default_json;
    };

    return parseAndResolve(ctx.arena, json, origin, opts);
}

fn fatalConfig(origin: []const u8, err: anyerror) noreturn {
    log("fatal: invalid sources config '{s}' ({s})", .{ origin, @errorName(err) });
    std.process.exit(1);
}

fn parseAndResolve(arena: Allocator, json: []const u8, origin: []const u8, opts: LoadOptions) !Config {
    const raw = try std.json.parseFromSliceLeaky(RawConfig, arena, json, .{});
    return resolve(arena, raw, origin, opts);
}

fn resolve(arena: Allocator, raw: RawConfig, origin: []const u8, opts: LoadOptions) (Allocator.Error || ValidationError)!Config {
    if (raw.version != 1) return error.UnsupportedVersion;
    if (raw.fast_interval_s == 0 or raw.slow_interval_s == 0) return error.InvalidInterval;

    var list: std.ArrayList(Source) = .empty;
    for (raw.sources) |rs| {
        if (rs.id.len == 0 or rs.url.len == 0 or rs.tier < 1 or rs.tier > 3) return error.InvalidSource;
        if (rs.poll.len != 0 and !std.mem.eql(u8, rs.poll, "fast") and !std.mem.eql(u8, rs.poll, "slow")) {
            return error.InvalidSource;
        }
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing.id, rs.id)) return error.DuplicateSourceId;
        }
        const kind = SourceKind.fromString(rs.kind) orelse return error.InvalidSource;
        if (!validProductionUrl(rs.url)) return error.InvalidSourceUrl;
        if (!validSourceSchema(rs, kind)) return error.InvalidSourceSchema;
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
        try list.append(arena, src);
    }

    try validateOverride(opts.only_csv, list.items);
    try validateOverride(opts.disable_csv, list.items);
    for (list.items) |source| {
        if (source.enabled) break;
    } else return error.NoEnabledSources;
    try validateCoverage(opts, list.items);

    return .{
        .version = raw.version,
        .fast_interval_s = raw.fast_interval_s,
        .slow_interval_s = raw.slow_interval_s,
        .sources = list.items,
        .origin = origin,
    };
}

fn validProductionUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null) return false;
    if (uri.user != null or uri.password != null) return false;
    if (uri.port != null and uri.port.? != 443) return false;
    for (url) |byte| if (std.ascii.isControl(byte) or byte == ' ') return false;
    return true;
}

fn validSourceSchema(raw: RawSource, kind: SourceKind) bool {
    if (raw.id.len == 0 or raw.kind.len == 0 or raw.url.len == 0) return false;
    for (raw.id) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    for (raw.match) |term| if (term.len == 0) return false;
    _ = kind;
    return true;
}

fn validateCoverage(opts: LoadOptions, sources: []const Source) ValidationError!void {
    var decisive_count: u32 = 0;
    for (sources) |source| {
        if (source.enabled and source.isDecisive()) decisive_count += 1;
    }
    if (opts.minimum_decisive_sources == 0 or opts.minimum_decisive_sources > decisive_count)
        return error.InvalidMinimumDecisiveSources;

    for (opts.required_source_ids, 0..) |id, i| {
        if (id.len == 0) return error.InvalidRequiredSource;
        for (opts.required_source_ids[0..i]) |prior| {
            if (std.mem.eql(u8, prior, id)) return error.DuplicateRequiredSource;
        }
        for (sources) |source| {
            if (!std.mem.eql(u8, source.id, id)) continue;
            if (!source.enabled or !source.isDecisive()) return error.InvalidRequiredSource;
            break;
        } else return error.InvalidRequiredSource;
    }
}

fn validateOverride(csv: ?[]const u8, sources: []const Source) ValidationError!void {
    var it = std.mem.splitScalar(u8, csv orelse return, ',');
    while (it.next()) |raw_id| {
        const id = std.mem.trim(u8, raw_id, " \t");
        if (id.len == 0) continue;
        for (sources) |source| {
            if (std.mem.eql(u8, source.id, id)) break;
        } else return error.UnknownSourceOverride;
    }
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

test "resolve builds the source list and applies defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var raw_sources = [_]RawSource{
        .{ .id = "probe", .kind = "model_list_probe", .tier = 1, .url = "https://example.test/models" },
    };
    const cfg = try resolve(arena_state.allocator(), .{ .version = 1, .sources = &raw_sources }, "test", .{});
    try testing.expectEqual(@as(usize, 1), cfg.sources.len);
    try testing.expectEqualStrings("probe", cfg.sources[0].id);
    try testing.expectEqual(PollClass.fast, cfg.sources[0].poll);
    try testing.expectEqualStrings("test", cfg.origin);
}

test "resolve rejects invalid schema and source selections" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const valid = [_]RawSource{
        .{ .id = "probe", .kind = "model_list_probe", .tier = 1, .url = "https://example.test/models" },
    };
    const two_valid = [_]RawSource{
        valid[0],
        .{ .id = "statement", .kind = "statement_watch", .tier = 1, .url = "https://example.test/statement" },
    };
    const duplicate = [_]RawSource{ valid[0], valid[0] };

    try testing.expectError(error.UnsupportedVersion, resolve(arena_state.allocator(), .{ .version = 2, .sources = @constCast(&valid) }, "test", .{}));
    try testing.expectError(error.UnsupportedVersion, resolve(arena_state.allocator(), .{ .sources = @constCast(&valid) }, "test", .{}));
    try testing.expectError(error.InvalidInterval, resolve(arena_state.allocator(), .{ .version = 1, .fast_interval_s = 0, .sources = @constCast(&valid) }, "test", .{}));
    try testing.expectError(error.DuplicateSourceId, resolve(arena_state.allocator(), .{ .version = 1, .sources = @constCast(&duplicate) }, "test", .{}));
    try testing.expectError(error.UnknownSourceOverride, resolve(arena_state.allocator(), .{ .version = 1, .sources = @constCast(&valid) }, "test", .{ .only_csv = "missing" }));
    try testing.expectError(error.NoEnabledSources, resolve(arena_state.allocator(), .{ .version = 1, .sources = @constCast(&valid) }, "test", .{ .disable_csv = "probe" }));
    try testing.expectError(error.InvalidRequiredSource, resolve(arena_state.allocator(), .{ .version = 1, .sources = @constCast(&valid) }, "test", .{ .required_source_ids = &.{"missing"} }));
    try testing.expectError(error.InvalidRequiredSource, resolve(arena_state.allocator(), .{ .version = 1, .sources = @constCast(&two_valid) }, "test", .{ .required_source_ids = &.{"probe"}, .disable_csv = "probe" }));
    try testing.expectError(error.DuplicateRequiredSource, resolve(arena_state.allocator(), .{ .version = 1, .sources = @constCast(&valid) }, "test", .{ .required_source_ids = &.{ "probe", "probe" } }));
    try testing.expectError(error.InvalidMinimumDecisiveSources, resolve(arena_state.allocator(), .{ .version = 1, .sources = @constCast(&valid) }, "test", .{ .minimum_decisive_sources = 2 }));
}

test "strict parser rejects every malformed critical config shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const invalid = [_][]const u8{
        "",
        "{}",

        \\{"version":1,"fast_interval_s":0,"sources":[]}
        ,
        \\{"version":1,"sources":[]}
        ,
        \\{"version":1,"sources":[{}]}
        ,
        \\{"version":1,"soruces":[]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"statement_watch","tier":1,"url":"http://example.com"}]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"statement_watch","tier":1,"url":"https://"}]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"statement_watch","tier":1,"url":"https://user@example.com"}]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"statement_watch","tier":1,"url":"https://example.com:8443"}]}
        ,
        \\{"version":1,"sources":[{"id":"bad id","kind":"statement_watch","tier":1,"url":"https://example.com"}]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"statement_watch","tier":1,"url":"https://example.com","matc":["x"]}]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"statement_watch","tier":1,"url":"https://example.com","match":[""]}]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"not_a_kind","tier":1,"url":"https://example.com"}]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"statement_watch","tier":4,"url":"https://example.com"}]}
        ,
        \\{"version":1,"sources":[{"id":"x","kind":"statement_watch","tier":1,"url":"https://example.com","poll":"often"}]}
        ,
    };
    for (invalid) |json| {
        try testing.expectError(error.InvalidConfig, parseInvalid(arena, json));
    }
}

fn parseInvalid(arena: Allocator, json: []const u8) error{InvalidConfig}!void {
    _ = parseAndResolve(arena, json, "test", .{}) catch return error.InvalidConfig;
    return;
}

test "recoverable loader reports explicit file errors and empty files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = Context{
        .io = testing.io,
        .arena = arena_state.allocator(),
        .state_path = "",
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 0,
    };
    const missing = ".test-fable-monitor-config-missing.json";
    const empty = ".test-fable-monitor-config-empty.json";
    std.Io.Dir.cwd().deleteFile(testing.io, missing) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, empty) catch {};

    try testing.expectError(error.FileNotFound, loadChecked(&ctx, .{ .sources_path = missing }));
    var file = try std.Io.Dir.cwd().createFile(testing.io, empty, .{});
    file.close(testing.io);
    try testing.expectError(error.InvalidConfig, loadInvalidFile(&ctx, empty));
}

test "both override lists reject typoed source IDs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var source = [_]RawSource{.{ .id = "probe", .kind = "statement_watch", .tier = 1, .url = "https://example.test/status" }};
    const raw = RawConfig{ .version = 1, .sources = &source };
    try testing.expectError(error.UnknownSourceOverride, resolve(arena_state.allocator(), raw, "test", .{ .only_csv = "proeb" }));
    try testing.expectError(error.UnknownSourceOverride, resolve(arena_state.allocator(), raw, "test", .{ .disable_csv = "proeb" }));
}

fn loadInvalidFile(ctx: *Context, path: []const u8) error{InvalidConfig}!void {
    _ = loadChecked(ctx, .{ .sources_path = path }) catch return error.InvalidConfig;
    return;
}

test "resolve propagates append failure instead of returning an empty config" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var raw_sources = [_]RawSource{
        .{ .id = "probe", .kind = "model_list_probe", .tier = 1, .url = "https://example.test/models" },
    };
    try testing.expectError(
        error.OutOfMemory,
        resolve(failing.allocator(), .{ .version = 1, .sources = &raw_sources }, "test", .{}),
    );
}

test "default config parses and yields the expected source kinds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const raw = try std.json.parseFromSliceLeaky(RawConfig, arena_state.allocator(), default_json, .{});
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
