//! The persisted monitor state. Serialized as line-delimited JSON, zstd-
//! compressed on disk. Each line is one `StateRecord`, tagged by `kind`.
//!
//! Format versioning: v1 wrote only `seen` and `hash` records and no `meta`
//! line. v2 adds a leading `meta` record carrying `state_version`, plus
//! `validator` (conditional-request ETag/Last-Modified), `model` (model ids
//! currently present per probe source), `feed` (seen feed-entry keys),
//! `status` (per-source timing for cadence and the coverage audit), and `alert`
//! (alert-once / escalation bookkeeping) records. A v1 file loads unchanged: the
//! absent `meta` defaults `version` to 1 and the unknown-to-v1 record kinds
//! simply never appear. Conversely a v2 file's extra records are ignored by the
//! lenient parse if read by an older build. So history is never invalidated.

const std = @import("std");
const Io = std.Io;
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;
const zstd = @import("zstd.zig");

/// The current on-disk state format version written by `saveState`.
pub const current_version: u32 = 2;

pub const State = struct {
    version: u32 = 1, // 1 when loaded from a pre-meta (v1) file
    federal_register_seen: [][]const u8 = &.{},
    keyword_hashes: []KeywordHash = &.{},
    validators: []Validator = &.{},
    model_present: []ModelPresent = &.{},
    feed_seen: []FeedSeen = &.{},
    source_status: []SourceStatus = &.{},
    alerts: []AlertRecord = &.{},

    pub const KeywordHash = struct {
        id: []const u8,
        hash: []const u8,
    };

    /// Cached conditional-request validators for a source, so the next poll can
    /// send If-None-Match / If-Modified-Since and get a cheap 304.
    pub const Validator = struct {
        id: []const u8,
        etag: []const u8 = "",
        last_modified: []const u8 = "",
    };

    /// One (source, model id) pair observed present in a model listing. The set
    /// of these is what an absent-to-present transition is detected against.
    pub const ModelPresent = struct {
        id: []const u8, // source id
        model: []const u8, // model identifier seen present
    };

    /// One (source, entry-key) pair already seen in a feed, so re-seeing it is
    /// not a change. Keys are guids / links / sitemap loc URLs.
    pub const FeedSeen = struct {
        id: []const u8, // source id
        key: []const u8,
    };

    /// Per-source timing, for adaptive cadence (is this source due?) and the
    /// coverage audit (is a source quietly dead?).
    pub const SourceStatus = struct {
        id: []const u8,
        last_poll_ms: i64 = 0, // last attempt
        last_success_ms: i64 = 0, // last successful fetch
        last_change_ms: i64 = 0, // last time a change was detected
    };

    /// Alert-once / escalation bookkeeping, keyed on a normalized event
    /// identity so one real event alerts once even as it persists across polls.
    /// Carries enough of the original event (tier, kind, title, url) to re-emit
    /// an escalation later without the underlying signal having to re-appear.
    pub const AlertRecord = struct {
        event_identity: []const u8,
        epoch_ms: i64 = 0, // when first alerted
        acknowledged: bool = false,
        escalated: bool = false,
        tier: u8 = 0,
        ev_kind: []const u8 = "",
        title: []const u8 = "",
        url: []const u8 = "",
    };

    pub fn hashFor(self: State, id: []const u8) ?[]const u8 {
        for (self.keyword_hashes) |kh| {
            if (std.mem.eql(u8, kh.id, id)) return kh.hash;
        }
        return null;
    }

    pub fn hasSeen(self: State, doc: []const u8) bool {
        for (self.federal_register_seen) |d| {
            if (std.mem.eql(u8, d, doc)) return true;
        }
        return false;
    }

    pub fn validatorFor(self: State, id: []const u8) ?Validator {
        for (self.validators) |v| {
            if (std.mem.eql(u8, v.id, id)) return v;
        }
        return null;
    }

    pub fn modelIsPresent(self: State, source_id: []const u8, model: []const u8) bool {
        for (self.model_present) |m| {
            if (std.mem.eql(u8, m.id, source_id) and std.mem.eql(u8, m.model, model)) return true;
        }
        return false;
    }

    pub fn feedHasSeen(self: State, source_id: []const u8, key: []const u8) bool {
        for (self.feed_seen) |f| {
            if (std.mem.eql(u8, f.id, source_id) and std.mem.eql(u8, f.key, key)) return true;
        }
        return false;
    }

    pub fn statusFor(self: State, id: []const u8) ?SourceStatus {
        for (self.source_status) |s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    pub fn alertFor(self: State, identity: []const u8) ?AlertRecord {
        for (self.alerts) |a| {
            if (std.mem.eql(u8, a.event_identity, identity)) return a;
        }
        return null;
    }
};

// The state file is line-delimited JSON: one `StateRecord` per line, tagged by
// `kind`. The struct is the union of every record kind's fields, parsed
// leniently (`ignore_unknown_fields`, defaulted fields) so unknown kinds or
// extra keys load without error and missing keys default.
pub const StateRecord = struct {
    kind: []const u8 = "",
    version: u32 = 0,
    document_number: []const u8 = "",
    id: []const u8 = "",
    hash: []const u8 = "",
    etag: []const u8 = "",
    last_modified: []const u8 = "",
    model: []const u8 = "",
    key: []const u8 = "",
    event_identity: []const u8 = "",
    epoch_ms: i64 = 0,
    last_poll_ms: i64 = 0,
    last_success_ms: i64 = 0,
    last_change_ms: i64 = 0,
    acknowledged: bool = false,
    escalated: bool = false,
    tier: u8 = 0,
    ev_kind: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
};

/// Read and decode the state file: zstd-decompress, then parse one
/// `StateRecord` per line back into a `State`. Errors (missing file, bad
/// zstd) propagate to the caller, which treats them as "start fresh".
pub fn loadState(ctx: *Context) !State {
    const raw = try Io.Dir.cwd().readFileAlloc(
        ctx.io,
        ctx.state_path,
        ctx.arena,
        .limited(64 * 1024 * 1024),
    );
    const data = try zstd.decompress(ctx.io, ctx.arena, raw);
    return parse(ctx.arena, data);
}

/// Parse the decompressed NDJSON body into a `State`. Split out from
/// `loadState` so it can be unit-tested without touching disk or zstd.
pub fn parse(arena: std.mem.Allocator, data: []const u8) !State {
    var version: u32 = 1;
    var seen: std.ArrayList([]const u8) = .empty;
    var hashes: std.ArrayList(State.KeywordHash) = .empty;
    var validators: std.ArrayList(State.Validator) = .empty;
    var models: std.ArrayList(State.ModelPresent) = .empty;
    var feeds: std.ArrayList(State.FeedSeen) = .empty;
    var statuses: std.ArrayList(State.SourceStatus) = .empty;
    var alerts: std.ArrayList(State.AlertRecord) = .empty;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        const parsed = std.json.parseFromSlice(StateRecord, arena, t, .{ .ignore_unknown_fields = true }) catch continue;
        const r = parsed.value;
        if (std.mem.eql(u8, r.kind, "meta")) {
            if (r.version > 0) version = r.version;
        } else if (std.mem.eql(u8, r.kind, "seen")) {
            if (r.document_number.len > 0) try seen.append(arena, r.document_number);
        } else if (std.mem.eql(u8, r.kind, "hash")) {
            try hashes.append(arena, .{ .id = r.id, .hash = r.hash });
        } else if (std.mem.eql(u8, r.kind, "validator")) {
            try validators.append(arena, .{ .id = r.id, .etag = r.etag, .last_modified = r.last_modified });
        } else if (std.mem.eql(u8, r.kind, "model")) {
            if (r.id.len > 0 and r.model.len > 0) try models.append(arena, .{ .id = r.id, .model = r.model });
        } else if (std.mem.eql(u8, r.kind, "feed")) {
            if (r.id.len > 0 and r.key.len > 0) try feeds.append(arena, .{ .id = r.id, .key = r.key });
        } else if (std.mem.eql(u8, r.kind, "status")) {
            try statuses.append(arena, .{
                .id = r.id,
                .last_poll_ms = r.last_poll_ms,
                .last_success_ms = r.last_success_ms,
                .last_change_ms = r.last_change_ms,
            });
        } else if (std.mem.eql(u8, r.kind, "alert")) {
            if (r.event_identity.len > 0) try alerts.append(arena, .{
                .event_identity = r.event_identity,
                .epoch_ms = r.epoch_ms,
                .acknowledged = r.acknowledged,
                .escalated = r.escalated,
                .tier = r.tier,
                .ev_kind = r.ev_kind,
                .title = r.title,
                .url = r.url,
            });
        }
    }
    return .{
        .version = version,
        .federal_register_seen = seen.items,
        .keyword_hashes = hashes.items,
        .validators = validators.items,
        .model_present = models.items,
        .feed_seen = feeds.items,
        .source_status = statuses.items,
        .alerts = alerts.items,
    };
}

/// Serialize `state` as line-delimited JSON records, zstd-compress, and write
/// the result to the state file (a full rewrite, as before). Writes a leading
/// `meta` record stamping the current format version.
pub fn saveState(ctx: *Context, state: State) !void {
    var buf: std.ArrayList(u8) = .empty;
    try writeRecord(ctx.arena, &buf, .{ .kind = "meta", .version = current_version });
    for (state.federal_register_seen) |d| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "seen", .document_number = d });
    }
    for (state.keyword_hashes) |kh| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "hash", .id = kh.id, .hash = kh.hash });
    }
    for (state.validators) |v| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "validator", .id = v.id, .etag = v.etag, .last_modified = v.last_modified });
    }
    for (state.model_present) |m| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "model", .id = m.id, .model = m.model });
    }
    for (state.feed_seen) |f| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "feed", .id = f.id, .key = f.key });
    }
    for (state.source_status) |s| {
        try writeRecord(ctx.arena, &buf, .{
            .kind = "status",
            .id = s.id,
            .last_poll_ms = s.last_poll_ms,
            .last_success_ms = s.last_success_ms,
            .last_change_ms = s.last_change_ms,
        });
    }
    for (state.alerts) |a| {
        try writeRecord(ctx.arena, &buf, .{
            .kind = "alert",
            .event_identity = a.event_identity,
            .epoch_ms = a.epoch_ms,
            .acknowledged = a.acknowledged,
            .escalated = a.escalated,
            .tier = a.tier,
            .ev_kind = a.ev_kind,
            .title = a.title,
            .url = a.url,
        });
    }

    const compressed = try zstd.compress(ctx.io, ctx.arena, buf.items);
    var file = try Io.Dir.cwd().createFile(ctx.io, ctx.state_path, .{});
    defer file.close(ctx.io);
    try file.writeStreamingAll(ctx.io, compressed);
    log("state written to {s} (v{d}, {d} bytes compressed)", .{ ctx.state_path, current_version, compressed.len });
}

/// Stringify one record (omitting empty/zero fields keeps lines compact) and
/// append it plus a newline to `buf`.
fn writeRecord(arena: std.mem.Allocator, buf: *std.ArrayList(u8), rec: StateRecord) !void {
    const line = try std.json.Stringify.valueAlloc(arena, rec, .{ .emit_strings_as_arrays = false });
    try buf.appendSlice(arena, line);
    try buf.append(arena, '\n');
}

/// Keep only the most recent `max` entries (the tail), so the seen-document
/// list does not grow without bound across runs.
pub fn capTail(items: [][]const u8, max: usize) [][]const u8 {
    if (items.len <= max) return items;
    return items[items.len - max ..];
}

const testing = std.testing;

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
        .model_present = @constCast(&[_]State.ModelPresent{
            .{ .id = "anthropic_model_list", .model = "claude-fable-5" },
        }),
    };
    try testing.expect(st.hasSeen("2026-001"));
    try testing.expect(!st.hasSeen("2026-999"));
    try testing.expectEqualStrings("deadbeef", st.hashFor("anthropic_news").?);
    try testing.expect(st.hashFor("missing") == null);
    try testing.expect(st.modelIsPresent("anthropic_model_list", "claude-fable-5"));
    try testing.expect(!st.modelIsPresent("anthropic_model_list", "claude-mythos-5"));
}

test "v1 file (no meta, only seen/hash) loads as version 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const data =
        \\{"kind":"seen","document_number":"2026-100"}
        \\{"kind":"hash","id":"bis_news","hash":"abc123"}
    ;
    const st = try parse(arena_state.allocator(), data);
    try testing.expectEqual(@as(u32, 1), st.version);
    try testing.expect(st.hasSeen("2026-100"));
    try testing.expectEqualStrings("abc123", st.hashFor("bis_news").?);
}

test "v2 records round-trip through parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const data =
        \\{"kind":"meta","version":2}
        \\{"kind":"validator","id":"fr_bis","etag":"\"v1\"","last_modified":"Mon, 01 Jan 2026 00:00:00 GMT"}
        \\{"kind":"model","id":"anthropic_model_list","model":"claude-fable-5"}
        \\{"kind":"feed","id":"google_news","key":"https://example.com/a"}
        \\{"kind":"status","id":"fr_bis","last_poll_ms":1000,"last_success_ms":900,"last_change_ms":0}
        \\{"kind":"alert","event_identity":"model:claude-fable-5","epoch_ms":1234,"acknowledged":false,"escalated":false}
    ;
    const st = try parse(arena_state.allocator(), data);
    try testing.expectEqual(@as(u32, 2), st.version);
    try testing.expectEqualStrings("\"v1\"", st.validatorFor("fr_bis").?.etag);
    try testing.expect(st.modelIsPresent("anthropic_model_list", "claude-fable-5"));
    try testing.expect(st.feedHasSeen("google_news", "https://example.com/a"));
    try testing.expectEqual(@as(i64, 900), st.statusFor("fr_bis").?.last_success_ms);
    try testing.expectEqual(@as(i64, 1234), st.alertFor("model:claude-fable-5").?.epoch_ms);
}
