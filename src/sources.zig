//! The set of official sources the monitor polls, plus the keyword vocabulary
//! that marks fetched content as relevant.

/// Keywords that mark a fetched page as relevant. Case-insensitive.
pub const keywords = [_][]const u8{ "fable", "mythos", "anthropic" };

pub const SourceKind = enum {
    /// Federal Register JSON API: track newly published document numbers.
    federal_register,
    /// Generic page: hash only the keyword-bearing context and diff that.
    keyword_watch,
};

pub const Source = struct {
    id: []const u8,
    kind: SourceKind,
    url: []const u8,
    label: []const u8,
    /// Keywords that mark content from this source as high-signal. For
    /// keyword_watch sources this is also the set whose context is diffed.
    match: []const []const u8 = &keywords,
};

pub const sources = [_]Source{
    .{
        .id = "fr_anthropic",
        .kind = .federal_register,
        .label = "Federal Register (term: Anthropic)",
        .url = "https://www.federalregister.gov/api/v1/documents.json" ++
            "?per_page=20&order=newest&conditions%5Bterm%5D=Anthropic",
    },
    .{
        .id = "fr_bis",
        .kind = .federal_register,
        .label = "Federal Register (Bureau of Industry and Security rules)",
        .url = "https://www.federalregister.gov/api/v1/documents.json" ++
            "?per_page=20&order=newest&conditions%5Bagencies%5D%5B%5D=industry-and-security-bureau",
    },
    .{
        .id = "anthropic_news",
        .kind = .keyword_watch,
        .label = "Anthropic newsroom",
        .url = "https://www.anthropic.com/news",
        // "anthropic" appears site-wide here, so key on the model names only.
        .match = &.{ "fable", "mythos" },
    },
    .{
        .id = "bis_news",
        .kind = .keyword_watch,
        .label = "Bureau of Industry and Security news",
        .url = "https://www.bis.gov/news-updates",
    },
};
