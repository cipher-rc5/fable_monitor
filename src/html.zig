//! Pure text helpers: HTML normalization and the keyword-context fingerprint
//! used to diff watched pages. No I/O — just functions over byte slices.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Build a stable fingerprint of the keyword-relevant content on a page.
///
/// Raw HTML is far too volatile to hash directly (minified markup, rotating
/// session tokens, reordered blocks). So we: strip tags, collapse whitespace,
/// lowercase, then keep only a small context window around each keyword hit,
/// and finally sort + dedupe those windows. The result changes when the
/// substance near a watched keyword changes, and stays put otherwise.
pub fn extractKeywordContext(arena: Allocator, body: []const u8, kws: []const []const u8) ![]u8 {
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
pub fn normalizeHtml(arena: Allocator, body: []const u8) ![]u8 {
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

/// Order comparator for sorting context windows lexicographically.
pub fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// True if any of `needles` occurs in `haystack`.
pub fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

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
