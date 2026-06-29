//! A deliberately small RSS / Atom / sitemap extractor. Std ships no XML
//! parser, and a full one is unnecessary: feeds we watch are well-formed and we
//! need only a stable per-entry identity (guid / link / sitemap loc), a title,
//! and a publication timestamp. Parsing this structure instead of fingerprinting
//! rendered HTML is what cuts the bulk of layout-churn false positives
//! (Workstream 3). Tolerant by design: it scans for the tags it knows and
//! ignores everything else, so unexpected markup degrades to fewer fields, not
//! an error.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    /// Stable identity: guid (RSS), id (Atom), or loc (sitemap), falling back to
    /// the link. Used as the cross-poll seen-key and the event identity.
    key: []const u8,
    title: []const u8 = "",
    /// Raw publication timestamp text (pubDate / updated / lastmod), if present.
    published: []const u8 = "",
};

/// Parse `body` as RSS, Atom, or a sitemap (auto-detected) into entries.
pub fn parse(arena: Allocator, body: []const u8) ![]Entry {
    if (std.mem.indexOf(u8, body, "<item") != null) return parseBlocks(arena, body, "item", .rss);
    if (std.mem.indexOf(u8, body, "<entry") != null) return parseBlocks(arena, body, "entry", .atom);
    if (std.mem.indexOf(u8, body, "<url") != null) return parseBlocks(arena, body, "url", .sitemap);
    return &.{};
}

const Flavor = enum { rss, atom, sitemap };

fn parseBlocks(arena: Allocator, body: []const u8, comptime tag: []const u8, flavor: Flavor) ![]Entry {
    const open = "<" ++ tag;
    const close = "</" ++ tag ++ ">";
    var entries: std.ArrayList(Entry) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, open)) |s| {
        // Advance past the opening tag's '>' so we read the element's content.
        const gt = std.mem.indexOfScalarPos(u8, body, s, '>') orelse break;
        const inner_start = gt + 1;
        const end = std.mem.indexOfPos(u8, body, inner_start, close) orelse break;
        const block = body[inner_start..end];
        pos = end + close.len;

        const e = entryFromBlock(block, flavor) catch continue;
        if (e.key.len > 0) try entries.append(arena, e);
    }
    return entries.items;
}

fn entryFromBlock(block: []const u8, flavor: Flavor) !Entry {
    return switch (flavor) {
        .rss => .{
            .key = pick(&.{ innerText(block, "guid"), innerText(block, "link") }) orelse "",
            .title = innerText(block, "title") orelse "",
            .published = innerText(block, "pubDate") orelse "",
        },
        .atom => .{
            .key = pick(&.{ innerText(block, "id"), linkHref(block) }) orelse "",
            .title = innerText(block, "title") orelse "",
            .published = pick(&.{ innerText(block, "updated"), innerText(block, "published") }) orelse "",
        },
        .sitemap => .{
            .key = innerText(block, "loc") orelse "",
            .title = innerText(block, "loc") orelse "",
            .published = innerText(block, "lastmod") orelse "",
        },
    };
}

/// First non-null, non-empty candidate.
fn pick(candidates: []const ?[]const u8) ?[]const u8 {
    for (candidates) |c| {
        if (c) |v| if (v.len > 0) return v;
    }
    return null;
}

/// Inner text of the first `<tag ...>...</tag>` in `block`, trimmed and with a
/// single surrounding CDATA wrapper removed. Null if absent.
pub fn innerText(block: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag;
    const close = "</" ++ tag ++ ">";
    const s = std.mem.indexOf(u8, block, open) orelse return null;
    // Reject a longer tag that merely shares this prefix (e.g. "link" vs "linkfoo").
    const after = block[s + open.len];
    if (after != '>' and after != ' ' and after != '\t' and after != '\r' and after != '\n' and after != '/') return null;
    const gt = std.mem.indexOfScalarPos(u8, block, s, '>') orelse return null;
    const end = std.mem.indexOfPos(u8, block, gt + 1, close) orelse return null;
    var text = std.mem.trim(u8, block[gt + 1 .. end], " \r\n\t");
    text = stripCdata(text);
    return std.mem.trim(u8, text, " \r\n\t");
}

fn stripCdata(text: []const u8) []const u8 {
    const pre = "<![CDATA[";
    const suf = "]]>";
    if (std.mem.startsWith(u8, text, pre) and std.mem.endsWith(u8, text, suf)) {
        return text[pre.len .. text.len - suf.len];
    }
    return text;
}

/// Atom links carry the URL in an `href` attribute: `<link href="..."/>`.
fn linkHref(block: []const u8) ?[]const u8 {
    const s = std.mem.indexOf(u8, block, "<link") orelse return null;
    const tag_end = std.mem.indexOfScalarPos(u8, block, s, '>') orelse return null;
    const tag = block[s..tag_end];
    const h = std.mem.indexOf(u8, tag, "href=") orelse return null;
    const after = tag[h + "href=".len ..];
    if (after.len == 0) return null;
    const q = after[0];
    if (q != '"' and q != '\'') return null;
    const close = std.mem.indexOfScalarPos(u8, after, 1, q) orelse return null;
    return after[1..close];
}

const testing = std.testing;

test "parse RSS items: guid identity, title, pubDate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rss =
        \\<rss><channel>
        \\<item><title>Anthropic export controls lifted</title>
        \\<link>https://news.example/a</link>
        \\<guid>tag:news,2026:a</guid>
        \\<pubDate>Mon, 01 Jan 2026 12:00:00 GMT</pubDate></item>
        \\<item><title>Unrelated</title><link>https://news.example/b</link><guid>tag:news,2026:b</guid></item>
        \\</channel></rss>
    ;
    const entries = try parse(arena_state.allocator(), rss);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("tag:news,2026:a", entries[0].key);
    try testing.expectEqualStrings("Anthropic export controls lifted", entries[0].title);
    try testing.expectEqualStrings("Mon, 01 Jan 2026 12:00:00 GMT", entries[0].published);
    try testing.expectEqualStrings("tag:news,2026:b", entries[1].key);
}

test "parse Atom entries: id identity and href link, CDATA title" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const atom =
        \\<feed><entry><title><![CDATA[Fable restored]]></title>
        \\<link href="https://a.example/x"/>
        \\<id>urn:x</id><updated>2026-01-01T00:00:00Z</updated></entry></feed>
    ;
    const entries = try parse(arena_state.allocator(), atom);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("urn:x", entries[0].key);
    try testing.expectEqualStrings("Fable restored", entries[0].title);
    try testing.expectEqualStrings("2026-01-01T00:00:00Z", entries[0].published);
}

test "parse sitemap urls: loc identity and lastmod" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const sm =
        \\<urlset><url><loc>https://www.anthropic.com/news/fable-mythos-access</loc><lastmod>2026-06-28</lastmod></url>
        \\<url><loc>https://www.anthropic.com/news/other</loc><lastmod>2026-06-01</lastmod></url></urlset>
    ;
    const entries = try parse(arena_state.allocator(), sm);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("https://www.anthropic.com/news/fable-mythos-access", entries[0].key);
    try testing.expectEqualStrings("2026-06-28", entries[0].published);
}

test "innerText does not match a tag that only shares a prefix" {
    // "<link>" must not be satisfied by "<linkbase>".
    try testing.expect(innerText("<linkbase>x</linkbase>", "link") == null);
    try testing.expectEqualStrings("y", innerText("<link>y</link>", "link").?);
}
