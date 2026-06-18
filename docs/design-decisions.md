# Design decisions

Last reviewed: 2026-06-18 · against fable-monitor 0.1.0

This file records *why* the tool is built the way it is, in lightweight ADR
(Architecture Decision Record) form. Each entry states the decision, the
context, and the trade-off accepted. When you revisit one of these, update the
entry rather than deleting the history.

---

## 1. One run = one poll (no daemon)

**Decision.** The binary performs a single poll and exits. Recurrence is the
scheduler's responsibility (launchd/cron).

**Why.** A short-lived process is far simpler to reason about and operate: no
event loop, no long-lived memory, no timer drift, and a crash costs at most one
poll. The OS schedulers are battle-tested and already solve "run this every N
minutes," including across reboots.

**Trade-off.** We depend on an external scheduler and accept poll-interval
granularity (we can't react faster than the schedule). For a slow-moving signal
like a regulatory change, minutes-to-an-hour latency is irrelevant.

---

## 2. Fetch via the system `curl` binary

**Decision.** All HTTP(S) fetching shells out to `curl` through
`std.process.run`, rather than using a Zig HTTP client.

**Why.** Zig is pre-1.0 and its in-tree TLS/HTTP client has churned across
releases; pinning to it would mean chasing breakage on every Zig bump. `curl`
is ubiquitous (present by default on macOS and virtually every Linux), handles
TLS correctly, and has a stable CLI. This keeps the program std-only for
everything *except* the fetch.

**Trade-off.** A runtime dependency on an external binary and a process spawn
per request. We mitigate the failure mode with a `toolAvailable()` preflight
(the shared `<name> --version` check, also used for `zstd`) that gives a clear
error instead of opaque per-source spawn failures. If Zig's
HTTP client stabilizes, this is the most likely decision to revisit — see the
code→doc map in [README.md](README.md).

---

## 3. State is a single file: zstd-compressed line-delimited JSON

**Decision.** Cross-run continuity is a single file on disk, read at start and
rewritten at end. No database. It is line-delimited JSON (one tagged record per
line — `kind:"seen"` / `kind:"hash"`), zstd-compressed.

**Why.** The state is tiny (a list of seen document numbers and a handful of
hashes), so a database would be vastly disproportionate. It was originally a
single pretty-printed JSON object; it is now JSONL so the whole codebase shares
one on-disk convention (the observation log is JSONL too), and zstd-compressed
for consistency with the other outputs (decision 11). The records are still
`std.json`-serialized and trivially inspectable — `zstd -dc state.jsonl.zst`
pipes straight to `jq` (see [state-format.md](state-format.md)).

**Trade-off.** No concurrent-writer safety and a full rewrite each run (both
non-issues under one-run-one-poll: one writer, small file). Compression means
the file is no longer editable in place — to hand-edit it for testing you
decompress, edit, and recompress (documented in [state-format.md](state-format.md)),
and the tool now depends on the `zstd` binary even to read its own state.

---

## 4. Two source classes: structured feed vs. keyword watch

**Decision.** Sources are split into `federal_register` (structured JSON API)
and `keyword_watch` (arbitrary HTML), handled by separate code paths.

**Why.** The Federal Register API gives stable, document-numbered records — a
high-reliability signal we can diff exactly. Arbitrary pages (the Anthropic
newsroom, BIS news) have no such structure, so they need a fuzzier approach.
Modeling the two explicitly keeps each path honest about its reliability: the
README tells the reader to weight the structured feed highest.

**Trade-off.** Two code paths to maintain. The alternative — forcing everything
through one mechanism — would either lose the precision of the structured feed
or fail entirely on unstructured pages.

---

## 5. Fingerprint keyword context, don't hash raw HTML

**Decision.** For keyword-watch sources, hash a normalized, keyword-windowed,
sorted, de-duplicated projection of the page — not the raw bytes.

**Why.** Raw HTML is noisy: minified markup, rotating CSRF/session tokens,
reordered blocks, and ads would all flip a naive hash and bury the real signal
in false positives. Reducing to "the text near our keywords" makes the
fingerprint change when the *substance* near a watched term changes, and stay
put otherwise. Sorting + de-duping the windows makes it robust to block
reordering.

**Trade-off.** We detect *that* something changed, not *what* — the alert points
a human at the page to look. We also accept that a determined redesign of a page
can still cause a one-time false positive. Both are acceptable for a
human-in-the-loop monitor. The ±100-byte window radius is a tunable in
`extractKeywordContext`.

---

## 6. Per-source error isolation

**Decision.** Each source's check is wrapped in its own error handler in
`main`; a failure logs and continues to the next source.

**Why.** A single flaky endpoint should never blind the monitor to the others.
Partial results are strictly better than no results for a monitoring tool.

**Trade-off.** A persistently failing source fails quietly (logged to stderr
only). Operationally you rely on reading logs / the absence of a baseline to
notice. Acceptable for the threat model; an alerting-on-repeated-failure feature
could be added later.

---

## 7. Notify hook via `sh -c <cmd> fable-monitor "$message"`

**Decision.** The user-supplied notify command receives the alert text as the
positional parameter `$1`, not interpolated into the command string.

**Why.** Interpolating an alert (which contains attacker-influenced text from a
fetched page) into a shell string would be a shell-injection hole. Passing it as
an argument vector to `sh -c` makes the text inert data. It also avoids
clobbering the child's environment.

**Trade-off.** The hook must reference `$1` rather than reading an env var or a
templated string. This is documented in the README and the plist example.

---

## 8. Arena allocation, freed wholesale on exit

**Decision.** All allocations come from one process-lifetime arena; nothing is
individually freed.

**Why.** A run is short and bounded, so memory cannot grow without limit within
a single poll. An arena eliminates an entire class of use-after-free / leak bugs
and removes free-bookkeeping noise from the code.

**Trade-off.** Peak memory is the sum of a run's allocations rather than a
rolling working set. Given the small payloads (capped fetch sizes, a handful of
sources), peak is trivial.

---

## 9. Observation history is a compressed JSONL log

**Decision.** Separately from the state snapshot, every poll records its findings
(new documents, keyword baselines/changes) as line-delimited JSON in a log file
(`FABLE_MONITOR_LOG`), zstd-compressed.

**Why.** The state file is overwritten each run, so it cannot answer "what
changed, and when?" A monitor's findings are exactly the data worth keeping over
time. JSONL is self-describing, `std.json`-serialized, and (decompressed)
inspectable with `jq`/`grep`. Sharing one timestamp per run keeps events from a
poll grouped. See [data-export.md](data-export.md).

**Trade-off.** Because the log is a single zstd stream, "append" is really a
read-modify-write: each run decompresses the existing log, adds its lines, and
recompresses. That is more work than the original open-and-append-at-the-end
approach, but the log grows with *events*, not poll frequency — a slow-moving
regulatory signal produces few rows — so the rewrite stays cheap. The log has no
automatic cap; rotation is left to the operator. We log events, not every poll,
so the file is not an uptime record.

---

## 10. Parquet is written by a minimal in-tree encoder, not a dependency

**Decision.** The `export` subcommand writes Parquet using a small, purpose-built
encoder in `src/parquet.zig` (Thrift compact metadata, `PLAIN` encoding,
all-`REQUIRED` columns, one row group) rather than linking a Parquet/Arrow
library or shelling out to DuckDB. Page compression is pluggable: the writer
takes an optional `Compressor` callback and, when given one, compresses each
page and tags the chunk with the ZSTD codec. The monitor always passes a
zstd-backed compressor (decision 11).

**Why.** This keeps the project std-only — the curl decision (decision 2)
already establishes that we add a dependency only when the alternative is worse.
A C/Arrow dependency would dwarf the program and reintroduce the build/ABI churn
we avoid; requiring DuckDB at runtime would push a heavy tool onto every
deployment for an occasional export. Keeping the encoder free of any
compression/process code (it just calls the callback) preserves that separation
while still producing standards-compliant ZSTD-coded Parquet that DuckDB,
pandas/pyarrow, and Polars read natively.

**Trade-off.** We own a (small) chunk of the Parquet spec, and still omit
dictionary encoding and column statistics — irrelevant at this scale. Each page
is compressed by spawning `zstd` once, so an export does a handful of spawns;
fine for an occasional, manual operation. Because std-only Zig can't parse
Parquet back, the encoder is validated by unit tests on its primitives plus an
end-to-end read with a real reader; see [data-export.md](data-export.md).

---

## 11. Compression is delegated to the system `zstd` binary

**Decision.** All zstandard compression — the state file, the observation log,
and Parquet pages — runs through the system `zstd` binary via `std.process.run`,
the same delegation pattern as curl (decision 2). The preflight (`toolAvailable`)
requires `zstd` in both poll and export modes.

**Why.** Zig 0.16's standard library ships a zstd *decompressor* but no
compressor, so in-process zstd is not available std-only. The alternatives were
linking libzstd (a C dependency — the very build/ABI churn the curl decision
avoids) or substituting gzip (which std *can* compress, but the request was
specifically zstandard). Delegating keeps the program std-only and gets a
battle-tested, well-tuned encoder for free. We delegate *decompression* to the
binary too, rather than mixing in std's decoder, so there is a single code path
and no second set of edge cases (window sizes, multi-frame streams).

**Implementation note.** `std.process.run` cannot feed a child's stdin, so input
is staged in a temp file that `zstd` reads while we drain its stdout — this also
sidesteps any pipe-buffer deadlock. Runs are single-threaded (one poll at a
time), so a fixed temp filename is safe; it is removed after each call.

**Trade-off.** A second runtime dependency, and `zstd` is less universally
preinstalled than `curl` (notably it is not guaranteed on older macOS), so the
preflight and docs call it out as a prerequisite. Compression/decompression cost
a process spawn plus a temp-file write each — negligible at this tool's volume
and cadence. If Zig's std gains a zstd compressor, this is the decision to
revisit (it would also let the state file be read without the binary present).

---

## 12. The `banner` renderer parses TrueType itself, with the font embedded

**Decision.** The `banner` subcommand (`src/banner.zig`) renders text with a
real TrueType font by parsing the sfnt tables and rasterizing the glyph outlines
from scratch — no font/graphics library. The font (*Manufacturing Consent*, SIL
OFL) is `@embedFile`d from `src/assets/` into the binary.

**Why.** It is the same calculus as the Parquet writer (decision 10): a font
library (FreeType/HarfBuzz) is a heavy C dependency for a cosmetic feature, and
shelling out to one (ImageMagick, etc.) adds a non-ubiquitous runtime
requirement. A few capital letters need only a small slice of the format
(format-4 `cmap`, simple `glyf` outlines, quadratic Béziers, non-zero-winding
scanline fill), which is tractable std-only. Embedding the font makes `banner`
work anywhere with zero external files; the OFL explicitly permits bundling, so
`src/assets/OFL.txt` ships alongside it. `@embedFile` cannot reference paths
outside the module directory, which is why the asset lives under `src/`.

**Trade-off.** It is not a general font engine — no hinting, kerning, composite
glyphs, antialiasing, or right-to-left — and at small sizes a blackletter face
is inherently busy. That is fine for a one-word vanity banner. The binary
carries a ~60 KB font, and the repo carries the font plus its license (a
deliberate, OFL-compliant choice; see decision and the
[font-delivery note](banner.md)).
