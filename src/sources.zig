//! The source model: confidence tiers, source kinds, the runtime `Source`
//! struct the poll loop consumes, and the keyword vocabularies. The concrete
//! list of sources is no longer hard-coded here; it is loaded at runtime from a
//! JSON config (an embedded default, overridable via FABLE_MONITOR_SOURCES) by
//! `config.zig`, which produces `Source` values described by this module.

const std = @import("std");

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
    // Tag stripping can leave a digit abutting the next listing entry; that
    // is a real hit, unlike a letter-embedded one.
    try testing.expect(p("claude-opus-4-8claude-fable-5", "claude-fable-5"));
    // One clean hit wins even when another occurrence is negated (beyond the
    // negation window).
    try testing.expect(p("previously not available in some regions. as of this morning, access for fable 5 is available worldwide", "available"));
}
