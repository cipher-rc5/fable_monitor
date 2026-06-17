# Sources

Last reviewed: 2026-06-17 · against fable-monitor 0.1.0

A *source* is one thing the monitor polls. The full list lives in the `sources`
array at the top of `src/main.zig`, alongside the `keywords` constant and the
`Source` / `SourceKind` definitions. This document explains the model and how to
add or tune a source.

## The `Source` model

```zig
const Source = struct {
    id: []const u8,           // stable key; used in state + logs. Never reuse.
    kind: SourceKind,         // .federal_register | .keyword_watch
    url: []const u8,          // what curl fetches
    label: []const u8,        // human-readable name shown in alerts/logs
    match: []const []const u8 = &keywords,  // high-signal keywords (see below)
};
```

`match` defaults to the global `keywords` (`fable`, `mythos`, `anthropic`) but
can be overridden per source.

## The two kinds

### `.federal_register` — structured feed (high reliability)

Polls the Federal Register JSON API. The response is parsed into `FrResponse` /
`FrDoc` and each result is keyed by `document_number`:

- A number already in the state's seen-set is skipped.
- A new number is recorded and alerted. If the document **title** contains one
  of the source's `match` keywords, the alert is tagged `[RELEVANT]`; otherwise
  `[new]`.

The two shipped feeds are a full-text term search for "Anthropic" and all rules
from the Bureau of Industry and Security (BIS), the agency that issued the
directive being watched.

### `.keyword_watch` — HTML page (best effort)

Fetches an arbitrary page and reduces it to a fingerprint of the text near each
`match` keyword (see the fingerprinting explanation in
[architecture.md](architecture.md) and the rationale in
[design-decisions.md](design-decisions.md)). The fingerprint is compared to the
stored one:

- no stored hash → "baseline recorded" (first sighting, no alert);
- equal hash → "unchanged";
- different hash → `[CHANGED]` alert pointing at the URL.

Note the shipped `anthropic_news` source overrides `match` to
`{ "fable", "mythos" }` only, because "anthropic" appears site-wide on that
domain and would make the entire page count as keyword context.

## Adding a source

1. Append an entry to the `sources` array in `src/main.zig`.
2. Give it a **unique, stable `id`** — it keys the source's data in the state
   file and appears in logs. Changing an existing `id` orphans its stored state
   (the next run treats it as brand new and re-baselines).
3. Pick the `kind`:
   - Use `.federal_register` only for the Federal Register documents JSON API
     (the parsing is specific to that response shape).
   - Use `.keyword_watch` for any other HTML or text page.
4. Set a clear `label` (it shows up verbatim in alerts).
5. Optionally narrow `match` if the default keywords are too broad for that page
   (as `anthropic_news` does).

Example:

```zig
.{
    .id = "commerce_press",
    .kind = .keyword_watch,
    .label = "Dept. of Commerce press releases",
    .url = "https://www.commerce.gov/news/press-releases",
    .match = &.{ "fable", "mythos", "export control" },
},
```

After editing, run `just test` and then `just demo` to confirm the new source
baselines cleanly on the first run and reports "unchanged" on the second.

## Tuning existing sources

- **Federal Register queries** are just URL query strings. The API supports
  filtering by agency, date range, document type, and full-text term, so a feed
  can be tightened (fewer false positives) or broadened (more coverage) by
  editing its `url`. Keep `order=newest` and a sane `per_page`.
- **Keyword sets** — edit the global `keywords` constant to change the default
  for every source, or a source's `match` to change just that one.
- **Fingerprint window** — the ±100-byte radius is the `radius` local in
  `extractKeywordContext`. A larger radius captures more surrounding context
  (more sensitive, slightly noisier); a smaller one is tighter.

## When you change sources, update the docs

Per the [maintenance policy](README.md), changes to the `sources` array,
`keywords`, or the `Source`/`SourceKind` types must update this file and the
"What it watches" section of the top-level [README](../README.md) in the same
change.
