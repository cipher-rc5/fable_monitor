# Sources

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

A *source* is one thing the monitor polls. Sources are **no longer hard-coded**:
they are described by a JSON config document, loaded at runtime by
`src/config.zig` into the `Source` / `SourceKind` / `Tier` types defined in
`src/sources.zig`. A default config is embedded in the binary
(`src/sources_default.json`), so the monitor works out of the box; pointing
`FABLE_MONITOR_SOURCES` at a file replaces it. This document explains the tier
model, the config format, every source kind, and the enable/disable toggles.

## Confidence tiers

Every source carries a tier (1, 2, or 3). Alerts route and escalate by tier; the
tier-1 path is optimized for latency, the tier-2/3 paths for precision.

| Tier | Role | Examples |
|---|---|---|
| **tier1** | Authoritative, lowest latency, highest precision. A tier-1 change is *decisive*: it trips immediately at high confidence rather than waiting for corroboration. | public model listing, the Anthropic access-statement page |
| **tier2** | The official regulatory record. High precision but day-of (or hours-ahead) latency. Tripped as an advisory until corroborated. | Federal Register, Federal Register public inspection, BIS news |
| **tier3** | Early but noisy, advance warning only. Advisory; never auto-actioned on its own. | newsroom sitemap, Google News, prediction markets |

The default config ships **four tier-1 trippers**
(`anthropic_model_list`, `anthropic_pricing`, `anthropic_statement`, and the
`anthropic_api_models` API probe), so any one of them seeing restoration is
enough. The API probe is a structured authenticated listing signal, not a
completion/callability test, and
requires `ANTHROPIC_API_KEY`; when that is unset it is skipped and the other
three still cover the decisive path. These are separate endpoints, but the two
public HTML model pages share an operator/content family and are not counted as
independent corroboration by the promotion logic.

### Embedded endpoints

These are the current URLs in `src/sources_default.json`; an external config can
replace them without rebuilding.

| ID | URL |
|---|---|
| `anthropic_model_list` | <https://platform.claude.com/docs/en/about-claude/models/overview> |
| `anthropic_pricing` | <https://claude.com/pricing> |
| `anthropic_api_models` | <https://api.anthropic.com/v1/models?limit=100> |
| `anthropic_statement` | <https://www.anthropic.com/news/fable-mythos-access> |
| `fr_pi_bis` | `https://www.federalregister.gov/api/v1/public-inspection-documents.json?conditions%5Bagencies%5D%5B%5D=industry-and-security-bureau&per_page=20` |
| `fr_pi_anthropic` | `https://www.federalregister.gov/api/v1/public-inspection-documents.json?conditions%5Bterm%5D=Anthropic&per_page=20` |
| `fr_anthropic` | `https://www.federalregister.gov/api/v1/documents.json?per_page=20&order=newest&conditions%5Bterm%5D=Anthropic` |
| `fr_bis` | `https://www.federalregister.gov/api/v1/documents.json?per_page=20&order=newest&conditions%5Bagencies%5D%5B%5D=industry-and-security-bureau` |
| `bis_news` | <https://www.bis.gov/news-updates> |
| `anthropic_sitemap` | <https://www.anthropic.com/sitemap.xml> |
| `google_news` | `https://news.google.com/rss/search?q=Anthropic%20export%20control%20Fable%20Mythos&hl=en-US&gl=US&ceid=US:en` |
| `polymarket` | `https://clob.polymarket.com/prices-history?market=PLACEHOLDER&interval=1h` (disabled until configured) |

## The config file

The top-level shape:

```json
{
  "version": 1,
  "fast_interval_s": 45,
  "slow_interval_s": 1800,
  "sources": [ ... ]
}
```

| Field | Default | Meaning |
|---|---|---|
| `version` | 1 | Config schema version. |
| `fast_interval_s` | 45 | Cadence (seconds) for `fast`-poll sources (tier-1). Overridable per run with `FABLE_MONITOR_FAST_INTERVAL`. |
| `slow_interval_s` | 1800 | Cadence (seconds) for `slow`-poll sources (tier-2/3). |
| `sources` | (n/a) | The array of source objects. |

Each source object:

```json
{
  "id": "anthropic_model_list",
  "kind": "model_list_probe",
  "tier": 1,
  "label": "Anthropic public model listing",
  "url": "https://platform.claude.com/docs/en/about-claude/models/overview",
  "match": ["claude-fable-5", "claude-mythos-5"],
  "enabled": true,
  "poll": "fast",
  "lead_time": "decisive: absent-to-present is live-access confirmation"
}
```

| Field | Required | Default | Meaning |
|---|---|---|---|
| `id` | yes | (n/a) | Stable, unique, non-empty key; used in state, logs, and event identities. Never reuse or rename (renaming orphans state and re-baselines it). |
| `kind` | yes | (n/a) | One of the source kinds below; unknown kinds reject the configuration. |
| `tier` | no | 3 | 1, 2, or 3; an out-of-range value rejects the configuration. |
| `label` | no | `id` | Human-readable name shown in alerts and logs. |
| `url` | yes | (n/a) | What `curl` fetches. |
| `match` | no | by kind | Keyword / term / model-id set that marks this source's content high-signal; for the watch kinds it is also the set whose context is fingerprinted. When empty, defaults to a kind-appropriate vocabulary (model ids for `model_list_probe`, restoration terms for `statement_watch`, the global keywords otherwise). |
| `enabled` | no | true | Per-source on/off (see toggles below). |
| `poll` | no | by tier | `"fast"` or `"slow"`. Defaults to `fast` for tier-1, `slow` for tier-2/3. |
| `lead_time` | no | "" | Free-text note on the expected lead time of this source's signal. |

JSON decoding rejects unknown fields, and semantic validation is fail-closed for
the configuration as a whole. Unsupported schema versions, invalid intervals,
malformed/duplicate sources, non-HTTPS/credentialed/non-443 URLs, unknown
override IDs, invalid required
coverage, and an all-disabled effective set terminate startup. An explicitly
selected unreadable or invalid file never falls back to the embedded default.
All poll requests are HTTPS-only and do not follow redirects. A 3xx response is
a source failure rather than an unchecked hop; update and review a changed
endpoint in the source config instead of relying on redirect behavior.

## Source kinds

| `kind` | Tier (typical) | What it does |
|---|---|---|
| `model_list_probe` | 1 | Reads the public model listing (metadata only, never a completion) and detects an **absent-to-present** transition of the controlled model identifiers (`claude-fable-5`, `claude-mythos-5`). The first observation of a source is a baseline and never trips. The transition is the single most decisive, highest-precision confirmation that access is live. |
| `api_probe` | 1 | Parses the Anthropic `/v1/models` JSON schema and exact-matches only typed `data[].id` model objects. Requires `ANTHROPIC_API_KEY`; without it the source is skipped unless selected as required, in which case coverage fails. Auth uses a mode-0600 header file and authenticated requests do not follow redirects. |
| `statement_watch` | 1 | Persists the non-negated restoration terms near a controlled model reference. Only an absent-to-present term transition from a known successful v3+ baseline is high confidence; other context changes are advisory. |
| `federal_register` | 2 | Polls the published-documents JSON API and tracks stage-qualified document keys. Publication is reevaluated even if the number appeared in public inspection. A tightened relevance filter requires Anthropic or a specific model, not bare "fable". |
| `federal_register_public_inspection` | 2 | Reads the preliminary public-inspection feed. A normal response has `results`; the Federal Register's temporary `meta.pil_unavailability_message` envelope is recognized as a valid upstream shape by preflight, but a poll treats it as temporarily unavailable rather than as an empty result or schema drift. Documents post before official publication and use a distinct stage key. |
| `feed_watch` | 3 | Parses RSS / Atom / sitemap structure (guid / link / loc) instead of fingerprinting rendered HTML, which cuts layout-churn false positives. The first poll baselines the entire current backlog without alerting. |
| `keyword_watch` | 2/3 | The original best-effort signal for pages with no structured feed: hash a normalized, keyword-windowed projection of the page and diff it. Reports *that* something near a keyword changed, not *what*. |
| `market_watch` | 3 | Records the last prediction-market price and flags a `>= 0.10` move. Advisory only; its purpose is to reveal a coverage gap (a faster source than our own) rather than to auto-action. The shipped `polymarket` entry has `"enabled": false` because its URL still carries a `PLACEHOLDER` market id — flip it on (external config or `FABLE_MONITOR_ONLY`) only after substituting a real id. |

## Enabling and disabling sources

A source runs only if it is enabled. Three layers, applied in order:

1. **Config `enabled`** flag (defaults to true).
2. **`FABLE_MONITOR_ONLY="id1,id2"`**, a whitelist. If set, *only* the listed
   ids are enabled; everything else is off.
3. **`FABLE_MONITOR_DISABLE="id1,id2"`**, which force-disables the listed ids,
   even if `ONLY` enabled them.

`ONLY` wins over the config flag; `DISABLE` then wins over `ONLY`. This lets an
operator narrow coverage from the environment without editing the file, which is
exactly how the `just demo-restore` recipe scopes a fixture replay to the
tier-1 sources.

Sources also **fail closed at runtime**: one source erroring (network, parse,
...) logs an error and lets other sources run, but the run is at least degraded.
It is failed if required/minimum decisive freshness is absent. See
`FABLE_MONITOR_REQUIRED_SOURCES` and `FABLE_MONITOR_MIN_DECISIVE_SOURCES` in
[deployment.md](deployment.md), plus per-source error isolation in
[design-decisions.md](design-decisions.md).

## Overriding the config

Set `FABLE_MONITOR_SOURCES` to an absolute path to a JSON file in the config
shape above. Validate it with a dry poll against a throwaway state file
(`FABLE_MONITOR_STATE=/tmp/x.zst ... poll`) and confirm the startup line reports
the expected source count and origin. `fable-monitor preflight --json` then
checks egress and response shape for each enabled source. To edit the *defaults*, change
`src/sources_default.json` and rebuild. For automation, `preflight --json`
returns `fable-monitor.preflight/1` checks with stable categories for egress,
schema, and decisive coverage.

## The detection vocabularies

These constants in `src/sources.zig` back the default `match` sets:

- `keywords` (`fable`, `mythos`, `anthropic`): the default for
  `federal_register` and `keyword_watch`.
- `model_ids` (`claude-fable-5`, `claude-mythos-5`): the default for
  `model_list_probe`.
- `restoration_terms` (`restored`, `resumed`, `reinstated`, ...): these drive
  the high-confidence decision for `statement_watch`.
- `strong_terms` (`anthropic`, `fable 5`, `mythos 5`, `claude-fable-5`,
  `claude-mythos-5`): the tightened Federal Register relevance filter, so a
  decoy document like "a fable about microchips" does not trip.

## Designed-but-deferred: a classifier-confirmation sidecar

For ambiguous tier-2/3 changes, a future out-of-process step could call a
currently-available Claude model (for example Opus, **never** the controlled
Fable / Mythos models) to score how likely a scraped change indicates
restoration. It is **designed but not implemented**, and it is deliberately
**not on the critical path of a tier-1 trip**: the model listing and statement
signals trip on their own logic regardless. The design constraints are:

- **Gated behind the keyword pre-filter**, so the model is only consulted on
  changes that already passed cheap matching (it never sees every poll).
- **Prompt-injection hardened.** Scraped page text is untrusted and is passed in
  a delimited block; the model is instructed to treat it as data and ignore any
  embedded directives, and the input size is capped.
- **Never authoritative on its own.** The classifier's output cannot trip an
  alert unless the structured trip logic also agrees; it can only raise or lower
  confidence within the existing rules.

This keeps a possible future "is this real?" judgment cheap, safe, and strictly
advisory, without ever putting a model in the decisive path.

## When you change sources, update the docs

Per the [maintenance policy](README.md), changes to the `Source` / `SourceKind`
/ `Tier` types in `src/sources.zig`, the config schema in `src/config.zig`, or
the default config in `src/sources_default.json` must update this file and the
overview in the top-level [README](../README.md) in the same change.
