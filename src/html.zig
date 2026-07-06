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

/// Strip HTML tags, decode common entities, lowercase, and collapse all
/// whitespace runs to one space. Entities are decoded before the keyword
/// fingerprint ever sees the text, so a page flipping between `-` and `&#45;`
/// (or entity-encoding an identifier outright) neither noises nor evades the
/// fingerprint. Decoded `<` / `>` are content, not markup: `&lt;b&gt;` becomes
/// the literal text `<b>` rather than a stripped tag.
pub fn normalizeHtml(arena: Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    var last_space = true; // also trims leading whitespace
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '<') {
            in_tag = true;
            i += 1;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            i += 1;
            continue;
        }
        if (in_tag) {
            i += 1;
            continue;
        }

        if (c == '&') {
            if (decodeEntity(body[i..])) |ent| {
                i += ent.len;
                if (ent.cp == 0xA0 or (ent.cp < 0x80 and std.ascii.isWhitespace(@intCast(ent.cp)))) {
                    // &nbsp; and encoded ASCII whitespace collapse like any run.
                    if (!last_space) {
                        try out.append(arena, ' ');
                        last_space = true;
                    }
                } else if (ent.cp < 0x80) {
                    try out.append(arena, std.ascii.toLower(@intCast(ent.cp)));
                    last_space = false;
                } else {
                    var utf8: [4]u8 = undefined;
                    // Codepoint was range- and surrogate-checked by decodeEntity.
                    const n = std.unicode.utf8Encode(ent.cp, &utf8) catch unreachable;
                    try out.appendSlice(arena, utf8[0..n]);
                    last_space = false;
                }
                continue;
            }
        }

        if (std.ascii.isWhitespace(c)) {
            if (!last_space) {
                try out.append(arena, ' ');
                last_space = true;
            }
        } else {
            try out.append(arena, std.ascii.toLower(c));
            last_space = false;
        }
        i += 1;
    }
    // Drop a single trailing separator so equivalent content hashes identically
    // regardless of trailing markup/whitespace.
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.items;
}

const Entity = struct { cp: u21, len: usize };

/// Decode one HTML entity at the start of `s` (whose first byte is '&').
/// Handles the common named entities and numeric `&#NN;` / `&#xNN;` forms.
/// Null when `s` does not begin with a well-formed entity, in which case the
/// caller emits the '&' literally.
fn decodeEntity(s: []const u8) ?Entity {
    const named = .{
        .{ "&amp;", '&' },
        .{ "&lt;", '<' },
        .{ "&gt;", '>' },
        .{ "&quot;", '"' },
        .{ "&apos;", '\'' },
        .{ "&nbsp;", 0xA0 },
    };
    inline for (named) |n| {
        if (std.mem.startsWith(u8, s, n[0])) return .{ .cp = n[1], .len = n[0].len };
    }

    if (!std.mem.startsWith(u8, s, "&#")) return null;
    var i: usize = 2;
    var base: u8 = 10;
    if (i < s.len and (s[i] == 'x' or s[i] == 'X')) {
        base = 16;
        i += 1;
    }
    const digits_start = i;
    var cp: u32 = 0;
    while (i < s.len and s[i] != ';') : (i += 1) {
        const d = std.fmt.charToDigit(s[i], base) catch return null;
        cp = cp * base + d;
        if (cp > 0x10FFFF) return null; // caps growth: no overflow possible
    }
    if (i >= s.len or i == digits_start) return null; // no ';', or no digits
    if (cp >= 0xD800 and cp <= 0xDFFF) return null; // surrogates are not text
    return .{ .cp = @intCast(cp), .len = i + 1 };
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

test "normalizeHtml decodes common and numeric entities before matching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Named entities; &nbsp; collapses like ordinary whitespace.
    try testing.expectEqualStrings(
        "a & b",
        try normalizeHtml(arena, "A &amp;&nbsp;&nbsp; B"),
    );
    // Decoded angle brackets are content, not markup to strip.
    try testing.expectEqualStrings(
        "x <b> y",
        try normalizeHtml(arena, "x &lt;b&gt; y"),
    );
    // An entity-encoded model identifier normalizes to the plain form.
    try testing.expectEqualStrings(
        "claude-fable-5",
        try normalizeHtml(arena, "<b>Claude&#45;Fable&#x2D;5</b>"),
    );
    // Encoded ASCII whitespace (&#32; &#9;) collapses; &#x41; is 'A' → 'a'.
    try testing.expectEqualStrings(
        "a b",
        try normalizeHtml(arena, "&#x41;&#32;&#9;b"),
    );
    // Non-ASCII codepoints re-encode as UTF-8.
    try testing.expectEqualStrings("π", try normalizeHtml(arena, "&#960;"));
    // Malformed entities pass through literally, without eating what follows.
    try testing.expectEqualStrings("&zzz; &#; &# &", try normalizeHtml(arena, "&zzz; &#; &# &"));
    try testing.expectEqualStrings("&#999999999;", try normalizeHtml(arena, "&#999999999;"));
    try testing.expectEqualStrings("&#xd800;", try normalizeHtml(arena, "&#xD800;"));
    // Truncated entity at end of input.
    try testing.expectEqualStrings("&am", try normalizeHtml(arena, "&am"));
}

test "extractKeywordContext matches an entity-encoded keyword" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const kws = [_][]const u8{"claude-fable-5"};
    const plain = try extractKeywordContext(arena, "<h1>claude-fable-5 restored</h1>", &kws);
    const encoded = try extractKeywordContext(arena, "<h1>Claude&#45;Fable&#x2D;5 restored</h1>", &kws);
    try testing.expect(plain.len > 0);
    // Entity churn produces the identical fingerprint input.
    try testing.expectEqualStrings(plain, encoded);
}

/// Deterministic 64-bit LCG for the fuzz test below: fixed seed, no wall
/// clock or environment, so failures reproduce exactly.
fn lcgNext(state: *u64) usize {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return @intCast(state.* >> 33);
}

test "fuzz: normalizeHtml never crashes on mutated bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const seed_doc =
        "<p class=\"s\">Claude &amp; Fable &#45; status &lt;ok&gt;&nbsp;" ++
        "&#x2D;&#960; <b>claude-fable-5</b> &quot;live&quot; &apos;now&apos;</p>";
    var rng: u64 = 0xC0FFEE0DDF00D123;
    var buf: [seed_doc.len]u8 = undefined;

    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        @memcpy(&buf, seed_doc);
        // A handful of point mutations, biased toward markup/entity bytes.
        const n_mut = 1 + lcgNext(&rng) % 8;
        var m: usize = 0;
        while (m < n_mut) : (m += 1) {
            const at = lcgNext(&rng) % buf.len;
            buf[at] = switch (lcgNext(&rng) % 6) {
                0 => '<',
                1 => '>',
                2 => '&',
                3 => '#',
                4 => ';',
                else => @truncate(lcgNext(&rng)),
            };
        }
        // Then truncate at a random point, so every mutation is also exercised
        // against a torn tail.
        const cut = lcgNext(&rng) % (buf.len + 1);
        _ = arena_state.reset(.retain_capacity);
        _ = try normalizeHtml(arena_state.allocator(), buf[0..cut]);
    }
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
