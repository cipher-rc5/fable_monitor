# Design decisions

Last reviewed: 2026-06-17 · against fable-monitor 0.1.0

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
per request. We mitigate the failure mode with a `curlAvailable()` preflight
that gives a clear error instead of opaque per-source spawn failures. If Zig's
HTTP client stabilizes, this is the most likely decision to revisit — see the
code→doc map in [README.md](README.md).

---

## 3. State is a single JSON file

**Decision.** Cross-run continuity is a single JSON document on disk, read at
start and rewritten at end. No database.

**Why.** The state is tiny (a list of seen document numbers and a handful of
hashes). JSON is human-readable (you can inspect or hand-edit it to test — see
[development.md](development.md)), trivially serialized by `std.json`, and has
zero operational overhead. A database would be vastly disproportionate.

**Trade-off.** No concurrent-writer safety and a full rewrite each run. Both are
non-issues under the one-run-one-poll model: there is never more than one writer
and the file is small. See [state-format.md](state-format.md).

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
