//! The source model: confidence tiers, source kinds, the runtime `Source`
//! struct the poll loop consumes, and the keyword vocabularies. The concrete
//! list of sources is no longer hard-coded here; it is loaded at runtime from a
//! JSON config (an embedded default, overridable via FABLE_MONITOR_SOURCES) by
//! `config.zig`, which produces `Source` values described by this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const html = @import("html.zig");

/// Extract text a user could reasonably see from an HTML model listing. In
/// addition to comments and executable/style content, preformatted examples are
/// omitted: documentation examples are mentions, not listing evidence.
/// A separator is inserted at every element boundary so adjacent nodes cannot
/// manufacture or merge an identifier.
pub fn extractVisibleText(arena: Allocator, body: []const u8) ![]u8 {
    var filtered: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, body, i + 4, "-->")) |end| end + 3 else body.len;
            try filtered.append(arena, ' ');
            continue;
        }
        if (body[i] != '<') {
            try filtered.append(arena, body[i]);
            i += 1;
            continue;
        }

        const end = htmlTagEnd(body, i) orelse {
            try filtered.append(arena, body[i]);
            i += 1;
            continue;
        };
        const name = htmlTagName(body[i + 1 .. end]);
        const closing = firstNonSpace(body[i + 1 .. end]) == '/';
        if (!closing and isNonEvidenceElement(name)) {
            i = skipElement(body, end + 1, name);
            try filtered.append(arena, ' ');
            continue;
        }
        try filtered.appendSlice(arena, body[i .. end + 1]);
        try filtered.append(arena, ' ');
        i = end + 1;
    }
    return html.normalizeHtml(arena, filtered.items);
}

fn htmlTagEnd(body: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start + 1;
    while (i < body.len) : (i += 1) {
        if (quote != 0) {
            if (body[i] == quote) quote = 0;
        } else if (body[i] == '\'' or body[i] == '"') {
            quote = body[i];
        } else if (body[i] == '>') return i;
    }
    return null;
}

fn firstNonSpace(s: []const u8) u8 {
    for (s) |c| if (!std.ascii.isWhitespace(c)) return c;
    return 0;
}

fn htmlTagName(tag: []const u8) []const u8 {
    var start: usize = 0;
    while (start < tag.len and (std.ascii.isWhitespace(tag[start]) or tag[start] == '/')) start += 1;
    var end = start;
    while (end < tag.len and (std.ascii.isAlphanumeric(tag[end]) or tag[end] == '-')) end += 1;
    return tag[start..end];
}

fn isNonEvidenceElement(name: []const u8) bool {
    inline for (.{ "script", "style", "template", "noscript", "pre", "samp" }) |excluded| {
        if (std.ascii.eqlIgnoreCase(name, excluded)) return true;
    }
    return false;
}

fn skipElement(body: []const u8, after_open: usize, name: []const u8) usize {
    var i = after_open;
    while (i < body.len) {
        const lt = std.mem.indexOfScalarPos(u8, body, i, '<') orelse return body.len;
        const end = htmlTagEnd(body, lt) orelse return body.len;
        const tag = body[lt + 1 .. end];
        if (firstNonSpace(tag) == '/' and std.ascii.eqlIgnoreCase(htmlTagName(tag), name)) return end + 1;
        i = end + 1;
    }
    return body.len;
}

/// Keywords that mark a fetched page or document as relevant. Case-insensitive.
/// Used as the default `match` set for federal_register and keyword_watch
/// sources when a source does not specify its own.
pub const keywords = [_][]const u8{ "fable", "mythos", "anthropic" };

/// Restoration vocabulary: terms that, appearing near a model name on the
/// statement page, indicate export-control access has been restored. The
/// default `match` set for statement_watch sources is these plus the model
/// names, so the fingerprint shifts when restoration language appears.
///
/// All entries are substrings matched against lowercased, tag-stripped text
/// (see `html.normalizeHtml`), so a stem covers its inflections: "return"
/// catches "returns"/"returning"/"returned", "relaunch" catches "relaunched",
/// "reauthoriz" catches "reauthorized"/"reauthorization". Stems are kept long
/// enough to avoid loose hits (e.g. "return", not "back", which would match
/// "background"/"feedback").
///
/// The ambiguous stems ("available", "return", "authorization") appear in
/// suspension copy at least as often as in restoration copy ("not available",
/// "will return when authorized"), so the statement detector matches every
/// term through `presentOutsideNegation` rather than a bare substring test.
pub const restoration_terms = [_][]const u8{
    "restored",      "resumed",         "reinstated", "reauthoriz",
    "available",     "lifted",          "rescinded",  "vacated",
    "authorization", "general license", "return",     "relaunch",
    "reintroduc",    "re-enabl",        "reenabl",    "now live",
    "live again",    "back online",
};

/// Negation / suspension / conditional markers that disqualify a nearby term
/// or identifier hit. Matched as substrings of the lowercased window around a
/// hit, so "not available", "no longer available", "will return when
/// authorized", or a listing note like "claude-fable-5 remains restricted"
/// never reads as restoration. Tokens carry spaces where a bare stem would
/// over-match (" if " not "if"; "not " also covers "cannot "; "no " covers
/// "no longer"/"no authorization"; "n't " covers "won't"/"isn't";
/// "restricted" not "restrict", which would match the restorative
/// "restrictions have been lifted").
pub const negation_markers = [_][]const u8{
    "not ",       "n't ",        "no ",     "never",
    "without",    " unless",     " until",  " when ",
    " if ",       " once ",      "pending", "suspend",
    "restricted", "unavailable", "revoked", "remains",
    "denied",     "prohibited",  "blocked",
};

/// Bytes inspected on each side of a hit for `negation_markers`. Kept small so
/// distant prose ("... export restrictions." two sentences later) cannot veto
/// a genuinely clean hit.
pub const negation_window = 40;

/// Maximum distance between restoration language and a controlled model
/// reference on an unstructured statement page.
pub const restoration_window = 160;

/// True iff `needle` occurs in `text` at least once *outside* a negation /
/// suspension context. `text` must already be normalized (lowercased,
/// whitespace-collapsed; see `html.normalizeHtml`). A hit is disqualified when
/// it is embedded in a longer word ("available" inside "unavailable") or when
/// any negation marker appears within `negation_window` bytes on either side.
/// One clean hit anywhere suffices: a page can say both "previously
/// unavailable" and "now available" and still read as present.
///
/// The embedded-word check rejects a preceding *letter* only: every real
/// embedding ("unavailable", "preauthorization") abuts a letter, while tag
/// stripping can legitimately leave a digit abutting the next identifier
/// ("<li>claude-opus-4-8</li><li>claude-fable-5</li>" normalizes to
/// "claude-opus-4-8claude-fable-5").
pub fn presentOutsideNegation(text: []const u8, needle: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, needle)) |pos| {
        start = pos + needle.len;
        if (pos > 0 and std.ascii.isAlphabetic(text[pos - 1])) continue;
        const lo = pos -| negation_window;
        const hi = @min(text.len, pos + needle.len + negation_window);
        if (!containsMarker(text[lo..hi])) return true;
    }
    return false;
}

/// Exact identifier matching for model IDs. Unlike restoration stems, both
/// boundaries reject identifier characters so longer IDs cannot alias a target.
pub fn presentExactOutsideNegation(text: []const u8, needle: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, needle)) |pos| {
        start = pos + needle.len;
        if (!hasTokenBoundaries(text, pos, needle.len)) continue;
        const lo = pos -| negation_window;
        const hi = @min(text.len, pos + needle.len + negation_window);
        if (!containsMarker(text[lo..hi])) return true;
    }
    return false;
}

fn hasTokenBoundaries(text: []const u8, pos: usize, len: usize) bool {
    if (pos > 0 and isIdentifierByte(text[pos - 1])) return false;
    if (pos + len < text.len and isIdentifierByte(text[pos + len])) return false;
    return true;
}

fn isIdentifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
}

/// Require an un-negated restoration term to be associated with a controlled
/// model reference in the same bounded text window.
pub fn restorationNearModel(text: []const u8, term: []const u8) bool {
    const refs = [_][]const u8{ "claude-fable-5", "claude-mythos-5", "fable 5", "mythos 5" };
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, term)) |pos| {
        start = pos + term.len;
        if (pos > 0 and std.ascii.isAlphabetic(text[pos - 1])) continue;
        const lo = pos -| negation_window;
        const neg_hi = @min(text.len, pos + term.len + negation_window);
        if (containsMarker(text[lo..neg_hi])) continue;
        const ref_lo = pos -| restoration_window;
        const ref_hi = @min(text.len, pos + term.len + restoration_window);
        for (refs) |model| {
            if (std.mem.indexOf(u8, text[ref_lo..ref_hi], model) != null) return true;
        }
    }
    return false;
}

fn containsMarker(window: []const u8) bool {
    for (negation_markers) |m| {
        if (std.mem.indexOf(u8, window, m) != null) return true;
    }
    return false;
}

/// The model identifiers whose presence in a public model listing is the
/// single most decisive confirmation that access is live again. The default
/// `match` set for model_list_probe sources.
pub const model_ids = [_][]const u8{ "claude-fable-5", "claude-mythos-5" };

/// Strong relevance terms for Federal Register matching. The bare keywords
/// ("fable", "mythos") are too loose for regulatory text (an unrelated document
/// can use the word "fable"), so a document is only tagged relevant when it
/// names Anthropic or a specific model. This is the precision tightening called
/// for in Workstream 3 and is why the decoy "a fable about microchips" document
/// does not trip.
pub const strong_terms = [_][]const u8{
    "anthropic",      "fable 5",         "mythos 5",
    "claude-fable-5", "claude-mythos-5",
};

/// Confidence tier. Alerts route and escalate by tier; the tier-1 path is
/// optimized for latency, the tier-2/3 paths for precision.
pub const Tier = enum(u8) {
    /// Authoritative, lowest latency, highest precision (model list, statement).
    tier1 = 1,
    /// Official regulatory record (Federal Register, BIS).
    tier2 = 2,
    /// Early but noisy, advance warning only (newsroom, news, markets).
    tier3 = 3,

    pub fn fromInt(n: u8) Tier {
        return switch (n) {
            1 => .tier1,
            2 => .tier2,
            else => .tier3,
        };
    }

    pub fn int(self: Tier) u8 {
        return @intFromEnum(self);
    }
};

pub const SourceKind = enum {
    /// Federal Register JSON API: track newly published document numbers.
    federal_register,
    /// Federal Register public-inspection JSON: documents placed on public
    /// inspection before official publication (an earlier signal).
    federal_register_public_inspection,
    /// Generic page: hash only the keyword-bearing context and diff that.
    keyword_watch,
    /// Like keyword_watch but tier-1 and keyed on restoration vocabulary near
    /// the model names; the decisive statement-page change.
    statement_watch,
    /// Public model listing: detect an absent-to-present transition of the
    /// controlled model identifiers. Reads listing metadata only.
    model_list_probe,
    /// Anthropic `/v1/models` API: the ground-truth "callable" signal. Same
    /// absent-to-present detection as `model_list_probe`, but against the
    /// authoritative API listing. Requires `ANTHROPIC_API_KEY`; skipped when
    /// unset. Reads listing metadata only, never a completion.
    api_probe,
    /// RSS / Atom / sitemap: parse structure (guid/link/lastmod) instead of
    /// fingerprinting rendered HTML.
    feed_watch,
    /// Prediction-market state (e.g. Polymarket): record last price / movement.
    market_watch,

    pub fn fromString(s: []const u8) ?SourceKind {
        return std.meta.stringToEnum(SourceKind, s);
    }

    /// The source_kind string written to the observation log for this kind.
    pub fn logName(self: SourceKind) []const u8 {
        return @tagName(self);
    }
};

/// How often a source is polled relative to the scheduler's fast tick. Tier-1
/// sources default to `fast`; tier-2/3 default to `slow`.
pub const PollClass = enum { fast, slow };

/// A source the monitor polls. Strings are owned by the run arena (parsed from
/// config) or are static (defaults). `match` is the keyword/term/model-id set
/// that marks this source's content high-signal; for keyword/statement_watch it
/// is also the set whose context is fingerprinted and diffed.
pub const Source = struct {
    id: []const u8,
    kind: SourceKind,
    tier: Tier,
    url: []const u8,
    label: []const u8,
    match: []const []const u8 = &keywords,
    enabled: bool = true,
    poll: PollClass = .slow,
    /// Free-text note on the expected lead time of this source's signal.
    lead_time: []const u8 = "",

    /// True if this source's change should trip immediately at high confidence
    /// (tier-1) rather than raise an advisory awaiting corroboration.
    pub fn isDecisive(self: Source) bool {
        return self.tier == .tier1;
    }
};

const testing = std.testing;

test "Tier round-trips through its integer form" {
    try testing.expectEqual(Tier.tier1, Tier.fromInt(1));
    try testing.expectEqual(Tier.tier2, Tier.fromInt(2));
    try testing.expectEqual(Tier.tier3, Tier.fromInt(3));
    try testing.expectEqual(Tier.tier3, Tier.fromInt(99)); // unknown clamps to tier3
    try testing.expectEqual(@as(u8, 1), Tier.tier1.int());
}

test "SourceKind parses from and renders to its tag name" {
    try testing.expectEqual(SourceKind.model_list_probe, SourceKind.fromString("model_list_probe").?);
    try testing.expectEqual(SourceKind.api_probe, SourceKind.fromString("api_probe").?);
    try testing.expect(SourceKind.fromString("nope") == null);
    try testing.expectEqualStrings("statement_watch", SourceKind.statement_watch.logName());
    try testing.expectEqualStrings("api_probe", SourceKind.api_probe.logName());
}

test "tier-1 sources are decisive" {
    const s1 = Source{ .id = "x", .kind = .model_list_probe, .tier = .tier1, .url = "", .label = "" };
    const s2 = Source{ .id = "y", .kind = .federal_register, .tier = .tier2, .url = "", .label = "" };
    try testing.expect(s1.isDecisive());
    try testing.expect(!s2.isDecisive());
}

test "restoration vocabulary covers the 'returning' family without loose hits" {
    // Mirrors poll.zig's escalation check: substring match against lowercased,
    // tag-stripped text. Phrases the way a real announcement would word a return.
    const hit = struct {
        fn f(text: []const u8) bool {
            for (restoration_terms) |t| if (std.mem.indexOf(u8, text, t) != null) return true;
            return false;
        }
    }.f;

    // Restoration phrasings that must escalate to high-confidence.
    try testing.expect(hit("access to fable 5 is returning to the api"));
    try testing.expect(hit("fable 5 returns effective today"));
    try testing.expect(hit("we are relaunching fable and mythos"));
    try testing.expect(hit("fable 5 reintroduced for all customers"));
    try testing.expect(hit("fable 5 is now live again"));
    try testing.expect(hit("fable 5 is back online"));
    try testing.expect(hit("export access re-enabled for fable 5"));

    // Common substrings that must NOT trip the new stems (regression guard).
    try testing.expect(!hit("background information on export policy"));
    try testing.expect(!hit("we appreciate your feedback on the rollback"));
}

test "presentOutsideNegation rejects negated / suspension contexts" {
    const p = presentOutsideNegation;

    // The ambiguous stems inside the negation contexts the audit called out.
    try testing.expect(!p("claude fable 5 is not available", "available"));
    try testing.expect(!p("fable 5 is unavailable in your region", "available"));
    try testing.expect(!p("fable 5 is no longer available", "available"));
    try testing.expect(!p("fable 5 won't be available this quarter", "available"));
    try testing.expect(!p("access will return when authorized by bis", "return"));
    try testing.expect(!p("access will not return this quarter", "return"));
    try testing.expect(!p("no authorization has been granted", "authorization"));
    try testing.expect(!p("preauthorization forms are unrelated", "authorization"));

    // Mere-mention suspension copy naming a controlled identifier.
    try testing.expect(!p("note: claude-fable-5 remains restricted", "claude-fable-5"));
    try testing.expect(!p("claude-fable-5 is currently suspended", "claude-fable-5"));
    try testing.expect(!p("claude-fable-5 access is revoked pending review", "claude-fable-5"));

    // Clean hits must still read as present.
    try testing.expect(p("fable 5 is available to all customers today", "available"));
    try testing.expect(p("access to fable 5 has been restored", "restored"));
    try testing.expect(p("fable 5 returns effective today", "return"));
    try testing.expect(p("reauthorization granted for fable 5", "reauthoriz"));
    try testing.expect(p("models claude-opus-4-8 claude-fable-5 claude-mythos-5", "claude-fable-5"));
    // One clean hit wins even when another occurrence is negated (beyond the
    // negation window).
    try testing.expect(p("previously not available in some regions. as of this morning, access for fable 5 is available worldwide", "available"));
}

test "exact model matching enforces both identifier boundaries" {
    const p = presentExactOutsideNegation;
    try testing.expect(p("<li>claude-fable-5</li>", "claude-fable-5"));
    try testing.expect(!p("prefix-claude-fable-5", "claude-fable-5"));
    try testing.expect(!p("claude-fable-5-preview", "claude-fable-5"));
}

test "visible model text excludes comments executable content and examples" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try extractVisibleText(arena_state.allocator(),
        \\<!-- claude-fable-5 -->
        \\<script>window.model = "claude-fable-5";</script>
        \\<style>.claude-fable-5 { display: block }</style>
        \\<pre><code>curl -d '{"model":"claude-fable-5"}'</code></pre>
        \\<p>Available models:</p><span>claude-fable-5</span>
    );
    try testing.expectEqualStrings("available models: claude-fable-5", text);
}

test "visible model text preserves exact boundaries between elements" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try extractVisibleText(arena_state.allocator(), "<span>prefix</span><span>claude-fable-5</span><span>-preview</span>");
    try testing.expectEqualStrings("prefix claude-fable-5 -preview", text);
    try testing.expect(presentExactOutsideNegation(text, "claude-fable-5"));
}

test "restoration terms must be near a controlled model" {
    try testing.expect(restorationNearModel("access to fable 5 has been restored for all customers", "restored"));
    try testing.expect(!restorationNearModel("access has been restored. " ++ ("unrelated policy text " ** 12) ++ "fable 5 remains restricted", "restored"));
    try testing.expect(!restorationNearModel("the archive was restored successfully", "restored"));
}
