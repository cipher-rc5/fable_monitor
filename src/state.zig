//! The persisted monitor state: which Federal Register documents have been seen
//! and the latest keyword-context hash per watched page. Serialized as
//! line-delimited JSON, zstd-compressed on disk.

const std = @import("std");
const Io = std.Io;
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;
const zstd = @import("zstd.zig");

// State schema, serialized to JSON. Kept deliberately flat.
pub const State = struct {
    federal_register_seen: [][]const u8 = &.{},
    keyword_hashes: []KeywordHash = &.{},

    pub const KeywordHash = struct {
        id: []const u8,
        hash: []const u8,
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
};

// The state file is line-delimited JSON: one `StateRecord` per line, tagged by
// `kind`. `seen` records carry a `document_number`; `hash` records carry an
// `id`/`hash` pair. Parsed leniently (`ignore_unknown_fields`, defaulted
// fields) so unknown kinds or extra keys load without error.
pub const StateRecord = struct {
    kind: []const u8 = "",
    document_number: []const u8 = "",
    id: []const u8 = "",
    hash: []const u8 = "",
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

    var seen: std.ArrayList([]const u8) = .empty;
    var hashes: std.ArrayList(State.KeywordHash) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        const parsed = std.json.parseFromSlice(StateRecord, ctx.arena, t, .{ .ignore_unknown_fields = true }) catch continue;
        const r = parsed.value;
        if (std.mem.eql(u8, r.kind, "seen")) {
            if (r.document_number.len > 0) try seen.append(ctx.arena, r.document_number);
        } else if (std.mem.eql(u8, r.kind, "hash")) {
            try hashes.append(ctx.arena, .{ .id = r.id, .hash = r.hash });
        }
    }
    return .{ .federal_register_seen = seen.items, .keyword_hashes = hashes.items };
}

/// Serialize `state` as line-delimited JSON records, zstd-compress, and write
/// the result to the state file (a full rewrite, as before).
pub fn saveState(ctx: *Context, state: State) !void {
    var buf: std.ArrayList(u8) = .empty;
    for (state.federal_register_seen) |d| {
        const line = try std.json.Stringify.valueAlloc(ctx.arena, .{ .kind = "seen", .document_number = d }, .{});
        try buf.appendSlice(ctx.arena, line);
        try buf.append(ctx.arena, '\n');
    }
    for (state.keyword_hashes) |kh| {
        const line = try std.json.Stringify.valueAlloc(ctx.arena, .{ .kind = "hash", .id = kh.id, .hash = kh.hash }, .{});
        try buf.appendSlice(ctx.arena, line);
        try buf.append(ctx.arena, '\n');
    }

    const compressed = try zstd.compress(ctx.io, ctx.arena, buf.items);
    var file = try Io.Dir.cwd().createFile(ctx.io, ctx.state_path, .{});
    defer file.close(ctx.io);
    try file.writeStreamingAll(ctx.io, compressed);
    log("state written to {s} ({d} bytes compressed)", .{ ctx.state_path, compressed.len });
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
    };
    try testing.expect(st.hasSeen("2026-001"));
    try testing.expect(!st.hasSeen("2026-999"));
    try testing.expectEqualStrings("deadbeef", st.hashFor("anthropic_news").?);
    try testing.expect(st.hashFor("missing") == null);
}
