//! Poll orchestration: the heart of the monitor. One call to `run` is one poll.
//!
//! Pipeline per run:
//!   1. load the source config and previous state;
//!   2. select the sources that are *due* this tick (tier-1 fast loop, tier-2/3
//!      slow loop), unless a fixture/force run polls all of them;
//!   3. fetch each due source (conditional request; fixtures in test mode),
//!      timing it, failing closed per source so one error never aborts the poll;
//!   4. run the kind-specific detector, which records observations and emits
//!      trip *signals*;
//!   5. coalesce signals by a normalized event identity (so one real event with
//!      several corroborating sources yields one alert), decide confidence,
//!      and emit exactly one structured event + notification per new identity,
//!      with alert-once idempotency and escalation;
//!   6. persist merged state, append the observation log, ping the heartbeat.
//!
//! The tier-1 path (model-list absent-to-present, statement restoration-term
//! absent-to-present) is the decisive, lowest-latency signal and never waits
//! on any tier-2/3 enrichment.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const context = @import("context.zig");
const Context = context.Context;
const log = context.log;
const config = @import("config.zig");
const Config = config.Config;
const sources_mod = @import("sources.zig");
const Source = sources_mod.Source;
const Tier = sources_mod.Tier;
const SourceKind = sources_mod.SourceKind;
const PollClass = sources_mod.PollClass;
const fetch = @import("fetch.zig");
const html = @import("html.zig");
const feed = @import("feed.zig");
const state_mod = @import("state.zig");
const State = state_mod.State;
const events = @import("events.zig");
const Event = events.Event;

/// Runtime knobs gathered from the environment by `main`, so this module stays
/// free of direct environ access (and is unit-testable with explicit options).
pub const Options = struct {
    sources_path: ?[]const u8 = null,
    only_csv: ?[]const u8 = null,
    disable_csv: ?[]const u8 = null,
    /// When set, fetches read `<dir>/<source_id>` files instead of the network.
    fixtures_dir: ?[]const u8 = null,
    /// Poll every enabled source regardless of cadence (first run, fixtures, or
    /// FABLE_MONITOR_FORCE=1).
    force_all: bool = false,
    fast_interval_override: ?u32 = null,
    /// Structured-event sinks. Always emitted to stdout; additionally appended
    /// to this file and/or POSTed to this webhook when set.
    event_sink_path: ?[]const u8 = null,
    webhook_url: ?[]const u8 = null,
    heartbeat_url: ?[]const u8 = null,
    /// Re-fire an unacknowledged tier-1 alert after this many seconds.
    escalate_after_s: u32 = 3600,
    /// Write per-source fetch metric rows to the observation log (off by default
    /// so the log grows with events, not poll frequency).
    log_metrics: bool = false,
    /// Anthropic API key (ANTHROPIC_API_KEY) for `api_probe` sources. When null
    /// or empty, api_probe sources are skipped (never fetched) so the monitor
    /// runs fine without a key. Never logged; used only as a request header.
    anthropic_api_key: ?[]const u8 = null,
};

/// Detection confidence. `high` trips immediately; `advisory` waits for
/// corroboration (another source on the same identity, or a tier promotion).
pub const Confidence = enum { high, advisory };

/// A trip-worthy change emitted by a detector. Distinct from an `Event` (the
/// audit-log row): a signal drives the alert/coalescing path.
pub const Signal = struct {
    source: Source,
    confidence: Confidence,
    event_kind: []const u8,
    identity: []const u8,
    title: []const u8 = "",
    document_number: []const u8 = "",
    url: []const u8 = "",
    detail: []const u8 = "",
    publication_date: []const u8 = "",
    published_epoch_ms: i64 = 0,
};

/// Mutable per-run accumulator. Builders are merged into the next `State`.
const Run = struct {
    ctx: *Context,
    opts: Options,
    cfg: Config,
    prev: State,

    seen: std.ArrayList([]const u8) = .empty,
    hashes: std.ArrayList(State.KeywordHash) = .empty,
    validators: std.ArrayList(State.Validator) = .empty,
    models: std.ArrayList(State.ModelPresent) = .empty,
    terms: std.ArrayList(State.TermPresent) = .empty,
    feeds: std.ArrayList(State.FeedSeen) = .empty,
    statuses: std.ArrayList(State.SourceStatus) = .empty,
    alerts: std.ArrayList(State.AlertRecord) = .empty,
    signals: std.ArrayList(Signal) = .empty,
    polled: std.ArrayList([]const u8) = .empty,

    // metrics
    total_fetch_ms: i64 = 0,
    n_ok: usize = 0,
    n_304: usize = 0,
    n_fail: usize = 0,

    fn a(self: *Run) Allocator {
        return self.ctx.arena;
    }

    fn markPolled(self: *Run, id: []const u8) void {
        self.polled.append(self.a(), id) catch {};
    }

    fn wasPolled(self: *Run, id: []const u8) bool {
        for (self.polled.items) |p| if (std.mem.eql(u8, p, id)) return true;
        return false;
    }
};

/// Run one poll.
pub fn run(ctx: *Context, opts: Options) !void {
    const t_start = Io.Timestamp.now(ctx.io, .real).toMilliseconds();

    const cfg = config.load(ctx, .{
        .sources_path = opts.sources_path,
        .only_csv = opts.only_csv,
        .disable_csv = opts.disable_csv,
    });
    log("fable-monitor polling: {d} sources from {s}", .{ cfg.sources.len, cfg.origin });

    // Serialize the whole read-modify-write against concurrent polls/acks so
    // an overlapping cron tick cannot discard this run's writes (or vice
    // versa). Held until this run's state and log are persisted.
    var state_lock = try state_mod.acquireLock(ctx);
    defer state_lock.release(ctx.io);

    const prev: State = state_mod.loadState(ctx) catch |err| blk: {
        log("warning: could not read state ({s}); starting fresh", .{@errorName(err)});
        break :blk .{};
    };

    var r = Run{ .ctx = ctx, .opts = opts, .cfg = cfg, .prev = prev };

    // Carry forward the cumulative sets (seen FR docs, seen feed keys) and the
    // alert bookkeeping; per-source records are carried forward later for
    // sources we do not poll this tick.
    for (prev.federal_register_seen) |d| try r.seen.append(r.a(), d);
    for (prev.feed_seen) |f| try r.feeds.append(r.a(), f);
    for (prev.alerts) |al| try r.alerts.append(r.a(), al);

    const fast_interval = opts.fast_interval_override orelse cfg.fast_interval_s;

    for (cfg.sources) |src| {
        if (!src.enabled) continue;
        if (!isDue(&r, src, fast_interval)) {
            carryForward(&r, src);
            continue;
        }
        // api_probe needs a key: skip gracefully (no fetch, no error) when the
        // key is unset so the build/tests and the keyless poller run fine.
        if (src.kind == .api_probe and !hasApiKey(&r)) {
            log("source '{s}': api_probe skipped (ANTHROPIC_API_KEY unset)", .{src.id});
            carryForward(&r, src);
            continue;
        }
        pollOne(&r, src) catch |err| {
            // Fail closed: one source erroring must not abort the poll.
            log("error: source '{s}' failed: {s}", .{ src.id, @errorName(err) });
            handlePollFailure(&r, src);
        };
    }

    // Decide alerts from the collected signals (tiered + coalesced), then
    // escalate any decisive alert left unacknowledged past the window.
    try resolveTrips(&r);
    escalateStale(&r);

    // Persist merged state.
    const next = State{
        .federal_register_seen = state_mod.capTail(r.seen.items, 300),
        .keyword_hashes = r.hashes.items,
        .validators = r.validators.items,
        .model_present = r.models.items,
        .terms_present = r.terms.items,
        .feed_seen = capFeeds(&r, max_feed_seen_per_source),
        .source_status = r.statuses.items,
        .alerts = r.alerts.items,
    };
    state_mod.saveState(ctx, next) catch |err| {
        log("error: failed to persist state: {s}", .{@errorName(err)});
    };

    events.appendLog(ctx.io, ctx.arena, ctx.log_path, ctx.events.items) catch |err| {
        log("error: failed to append observation log: {s}", .{@errorName(err)});
    };

    const wall = Io.Timestamp.now(ctx.io, .real).toMilliseconds() - t_start;
    log("poll metrics: {d} ok, {d} not-modified, {d} failed; fetch {d}ms, wall {d}ms", .{
        r.n_ok, r.n_304, r.n_fail, r.total_fetch_ms, wall,
    });

    // Dead-man's switch: report liveness only after a clean run.
    if (opts.heartbeat_url) |hb| {
        const ok = fetch.pingHeartbeat(ctx, hb);
        log("heartbeat {s}", .{if (ok) "ok" else "FAILED (monitor liveness not reported)"});
    }

    if (!ctx.changed) log("no changes detected", .{});
}

// --- cadence ----------------------------------------------------------------

fn intervalFor(r: *Run, src: Source, fast_interval: u32) u32 {
    return switch (src.poll) {
        .fast => fast_interval,
        .slow => r.cfg.slow_interval_s,
    };
}

/// A source is due if forced, never polled, or its interval has elapsed since
/// the last attempt.
fn isDue(r: *Run, src: Source, fast_interval: u32) bool {
    if (r.opts.force_all or r.opts.fixtures_dir != null) return true;
    const st = r.prev.statusFor(src.id) orelse return true;
    const elapsed_ms = r.ctx.epoch_ms - st.last_poll_ms;
    return elapsed_ms >= @as(i64, intervalFor(r, src, fast_interval)) * 1000;
}

/// Re-emit the prior state records for a source we are not polling this tick,
/// or whose poll failed partway. Skips any record kind this run has already
/// produced for the source, so a partially completed `pollOne` (validators
/// persisted, then the detector failed) never yields duplicates.
fn carryForward(r: *Run, src: Source) void {
    if (!hasValidatorQueued(r, src.id)) {
        if (r.prev.validatorFor(src.id)) |v| r.validators.append(r.a(), v) catch {};
    }
    if (!hasHashQueued(r, src.id)) {
        if (r.prev.hashFor(src.id)) |h| r.hashes.append(r.a(), .{ .id = src.id, .hash = h }) catch {};
    }
    if (!hasStatusQueued(r, src.id)) {
        if (r.prev.statusFor(src.id)) |s| r.statuses.append(r.a(), s) catch {};
    }
    if (!hasModelQueued(r, src.id)) {
        for (r.prev.model_present) |m| {
            if (std.mem.eql(u8, m.id, src.id)) r.models.append(r.a(), m) catch {};
        }
    }
    if (!hasTermQueued(r, src.id)) {
        for (r.prev.terms_present) |t| {
            if (std.mem.eql(u8, t.id, src.id)) r.terms.append(r.a(), t) catch {};
        }
    }
}

/// The fail-closed path for a source whose poll errored: count it, stamp the
/// failed attempt, and carry the prior baseline (hash, validators,
/// model_present) forward. Without the carry-forward a transient fetch
/// failure would drop the baseline and the next successful poll would
/// re-baseline instead of tripping.
fn handlePollFailure(r: *Run, src: Source) void {
    r.n_fail += 1;
    recordStatus(r, src, false);
    carryForward(r, src);
}

fn hasValidatorQueued(r: *Run, id: []const u8) bool {
    for (r.validators.items) |v| if (std.mem.eql(u8, v.id, id)) return true;
    return false;
}

fn hasHashQueued(r: *Run, id: []const u8) bool {
    for (r.hashes.items) |h| if (std.mem.eql(u8, h.id, id)) return true;
    return false;
}

fn hasStatusQueued(r: *Run, id: []const u8) bool {
    for (r.statuses.items) |s| if (std.mem.eql(u8, s.id, id)) return true;
    return false;
}

fn hasModelQueued(r: *Run, id: []const u8) bool {
    for (r.models.items) |m| if (std.mem.eql(u8, m.id, id)) return true;
    return false;
}

fn hasTermQueued(r: *Run, id: []const u8) bool {
    for (r.terms.items) |t| if (std.mem.eql(u8, t.id, id)) return true;
    return false;
}

/// True when an Anthropic API key is configured (non-empty). Gates api_probe.
fn hasApiKey(r: *Run) bool {
    const key = r.opts.anthropic_api_key orelse return false;
    return key.len > 0;
}

/// Per-source cap on the persisted feed seen-key set. Capping per source id
/// (not globally) means one giant feed — a full sitemap baseline, say —
/// cannot evict another feed's seen keys and make its backlog re-alert.
const max_feed_seen_per_source = 500;

/// Keep only the newest `max_per_source` seen keys for each source id,
/// preserving order. An entry survives iff fewer than `max_per_source` newer
/// entries share its source id.
fn capFeeds(r: *Run, max_per_source: usize) []State.FeedSeen {
    const items = r.feeds.items;
    var kept: std.ArrayList(State.FeedSeen) = .empty;
    for (items, 0..) |f, i| {
        var newer: usize = 0;
        for (items[i + 1 ..]) |g| {
            if (std.mem.eql(u8, g.id, f.id)) newer += 1;
            if (newer >= max_per_source) break;
        }
        if (newer >= max_per_source) continue; // older than the newest N: drop
        kept.append(r.a(), f) catch return items;
    }
    return kept.items;
}

// --- fetch + dispatch -------------------------------------------------------

fn pollOne(r: *Run, src: Source) !void {
    r.markPolled(src.id);
    const ctx = r.ctx;

    // A market_watch URL still carrying the shipped PLACEHOLDER can never
    // resolve; say so once per poll instead of surfacing an opaque fetch error.
    if (src.kind == .market_watch and std.mem.indexOf(u8, src.url, "PLACEHOLDER") != null) {
        log("hint: source '{s}' URL contains PLACEHOLDER; set a real market id in the sources config", .{src.id});
    }

    const resp = try fetchSource(r, src);
    r.total_fetch_ms += resp.fetch_ms;

    // Persist the (possibly new) conditional-request validators.
    if (resp.etag.len > 0 or resp.last_modified.len > 0) {
        r.validators.append(r.a(), .{ .id = src.id, .etag = resp.etag, .last_modified = resp.last_modified }) catch {};
    } else if (r.prev.validatorFor(src.id)) |v| {
        r.validators.append(r.a(), v) catch {}; // keep prior validators on a 304
    }

    if (r.opts.log_metrics) try ctx.record(.{
        .source_id = src.id,
        .source_label = src.label,
        .source_kind = src.kind.logName(),
        .event = events.ev_fetch,
        .tier = src.tier.int(),
        .fetch_ms = resp.fetch_ms,
        .http_status = @intCast(resp.status),
    });

    recordStatus(r, src, true);
    r.n_ok += 1;

    if (resp.not_modified) {
        r.n_304 += 1;
        carryForwardContent(r, src); // unchanged: keep prior hash/models
        log("source '{s}': not modified (304)", .{src.id});
        return;
    }

    switch (src.kind) {
        .model_list_probe, .api_probe => try detectModelList(r, src, resp.body),
        .statement_watch => try detectKeywordOrStatement(r, src, resp.body, true),
        .keyword_watch => try detectKeywordOrStatement(r, src, resp.body, false),
        .federal_register, .federal_register_public_inspection => try detectFederalRegister(r, src, resp.body),
        .feed_watch => try detectFeed(r, src, resp.body),
        .market_watch => try detectMarket(r, src, resp.body),
    }
}

/// Keep prior per-source content records when a fetch returned 304.
fn carryForwardContent(r: *Run, src: Source) void {
    if (r.prev.hashFor(src.id)) |h| r.hashes.append(r.a(), .{ .id = src.id, .hash = h }) catch {};
    for (r.prev.model_present) |m| {
        if (std.mem.eql(u8, m.id, src.id)) r.models.append(r.a(), m) catch {};
    }
    for (r.prev.terms_present) |t| {
        if (std.mem.eql(u8, t.id, src.id)) r.terms.append(r.a(), t) catch {};
    }
}

const FetchResult = struct {
    status: u32 = 200,
    body: []u8 = &.{},
    etag: []const u8 = "",
    last_modified: []const u8 = "",
    not_modified: bool = false,
    fetch_ms: i64 = 0,
};

/// Fetch a source's body: from a fixture file in test mode, else a conditional
/// HTTP request carrying the persisted validators.
fn fetchSource(r: *Run, src: Source) !FetchResult {
    if (r.opts.fixtures_dir) |dir| {
        const path = try std.fmt.allocPrint(r.a(), "{s}/{s}", .{ dir, src.id });
        const body = Io.Dir.cwd().readFileAlloc(r.ctx.io, path, r.a(), .limited(16 * 1024 * 1024)) catch |err| {
            log("fixture missing for '{s}' at {s} ({s})", .{ src.id, path, @errorName(err) });
            return error.FetchFailed;
        };
        return .{ .body = body };
    }
    const v = r.prev.validatorFor(src.id) orelse State.Validator{ .id = src.id };
    // Attach the API key only for api_probe; every other source fetches with the
    // curl argv byte-for-byte unchanged.
    const api_key: ?[]const u8 = if (src.kind == .api_probe) r.opts.anthropic_api_key else null;
    const resp = try fetch.fetchConditional(r.ctx, src.url, v.etag, v.last_modified, api_key);
    return .{
        .status = resp.status,
        .body = resp.body,
        .etag = resp.etag,
        .last_modified = resp.last_modified,
        .not_modified = resp.not_modified,
        .fetch_ms = resp.fetch_ms,
    };
}

fn recordStatus(r: *Run, src: Source, success: bool) void {
    const prev = r.prev.statusFor(src.id);
    var st = State.SourceStatus{
        .id = src.id,
        .last_poll_ms = r.ctx.epoch_ms,
        .last_success_ms = if (prev) |p| p.last_success_ms else 0,
        .last_change_ms = if (prev) |p| p.last_change_ms else 0,
    };
    if (success) st.last_success_ms = r.ctx.epoch_ms;
    // Replace any status appended earlier this run, so a fetch success
    // followed by a detector failure persists one accurate record (the later
    // call wins on success; a `markChanged` stamp made in between survives).
    for (r.statuses.items) |*existing| {
        if (std.mem.eql(u8, existing.id, src.id)) {
            st.last_change_ms = @max(st.last_change_ms, existing.last_change_ms);
            existing.* = st;
            return;
        }
    }
    r.statuses.append(r.a(), st) catch {};
}

// --- detectors --------------------------------------------------------------

/// Tier-1, decisive: the controlled model identifiers transitioning from absent
/// to present in the public listing. Reads listing text only, never a
/// completion. First observation of a source is a baseline (we cannot know it is
/// a *transition* without a prior absent reading), so it never trips.
///
/// The docs/pricing HTML probes (`model_list_probe`) are prose pages that can
/// *mention* a controlled identifier inside suspension copy ("claude-fable-5
/// remains restricted"), so an identifier only counts as present there when it
/// appears outside a negation/suspension context. The `/v1/models` JSON
/// (`api_probe`) is a structured listing with no prose — a listed id *is*
/// presence — so it keeps the plain substring test.
fn detectModelList(r: *Run, src: Source, body: []const u8) !void {
    const text = try html.normalizeHtml(r.a(), body);
    const had_prior = hasPriorModels(r.prev, src.id);

    for (src.match) |model| {
        const lower = try std.ascii.allocLowerString(r.a(), model);
        const present = switch (src.kind) {
            .model_list_probe => sources_mod.presentOutsideNegation(text, lower),
            else => std.mem.indexOf(u8, text, lower) != null,
        };
        if (!present) continue;

        r.models.append(r.a(), .{ .id = src.id, .model = model }) catch {};

        const was_present = r.prev.modelIsPresent(src.id, model);
        if (!was_present and had_prior) {
            // Absent-to-present: the single most decisive confirmation.
            markChanged(r, src);
            const identity = try std.fmt.allocPrint(r.a(), "model_present:{s}", .{model});
            try r.signals.append(r.a(), .{
                .source = src,
                .confidence = .high,
                .event_kind = events.ev_restoration,
                .identity = identity,
                .title = try std.fmt.allocPrint(r.a(), "Model {s} present in public listing", .{model}),
                .url = src.url,
                .detail = model,
            });
        }
    }
    if (!had_prior) log("source '{s}': model-list baseline recorded", .{src.id});
}

fn hasPriorModels(prev: State, source_id: []const u8) bool {
    // "Prior" means we have polled this source before. A source with a status
    // record but no present models had an all-absent prior reading, which still
    // counts as a baseline for transition detection.
    if (prev.statusFor(source_id) != null) return true;
    for (prev.model_present) |m| {
        if (std.mem.eql(u8, m.id, source_id)) return true;
    }
    return false;
}

/// keyword_watch (tier-2/3) and statement_watch (tier-1) share the fingerprint
/// mechanism. For the statement page, restoration is a *transition*: a
/// restoration term that was absent at the persisted baseline flipping to
/// present — matched negation-aware, so suspension copy like "not available"
/// or "will return when authorized" never counts as present. A changed page
/// without such a flip is only ever advisory (the pre-transition semantics,
/// "hash changed AND term present", tripped on exactly that suspension copy).
fn detectKeywordOrStatement(r: *Run, src: Source, body: []const u8, is_statement: bool) !void {
    const blob = try html.extractKeywordContext(r.a(), body, src.match);
    const digest = std.hash.Wyhash.hash(0, blob);
    const hex = try std.fmt.allocPrint(r.a(), "{x:0>16}", .{digest});
    r.hashes.append(r.a(), .{ .id = src.id, .hash = hex }) catch {};

    // Statement pages persist which restoration terms are present this poll
    // (against the full normalized text, so detection does not depend on the
    // fingerprint's context windows). A flip is only trusted when the prior
    // state actually carried a term baseline: a pre-v3 state file has none,
    // and re-baselining silently beats trusting an unknowable transition.
    var flipped: std.ArrayList([]const u8) = .empty;
    const term_baseline_known = is_statement and
        r.prev.version >= state_mod.term_records_version and
        r.prev.statusFor(src.id) != null;
    if (is_statement) {
        const text = try html.normalizeHtml(r.a(), body);
        for (sources_mod.restoration_terms) |term| {
            if (!sources_mod.presentOutsideNegation(text, term)) continue;
            r.terms.append(r.a(), .{ .id = src.id, .term = term }) catch {};
            if (term_baseline_known and !r.prev.termIsPresent(src.id, term)) {
                flipped.append(r.a(), term) catch {};
            }
        }
    }

    const old = r.prev.hashFor(src.id);
    if (old == null) {
        log("source '{s}': baseline recorded ({d} keyword bytes)", .{ src.id, blob.len });
        try r.ctx.record(.{
            .source_id = src.id,
            .source_label = src.label,
            .source_kind = src.kind.logName(),
            .event = events.ev_baseline,
            .tier = src.tier.int(),
            .url = src.url,
            .detail = hex,
        });
        return;
    }
    if (is_statement and !term_baseline_known) {
        log("source '{s}': statement term baseline recorded (pre-v{d} state)", .{ src.id, state_mod.term_records_version });
    }
    const hash_changed = !std.mem.eql(u8, old.?, hex);
    if (!hash_changed and flipped.items.len == 0) {
        log("source '{s}': unchanged", .{src.id});
        return;
    }

    markChanged(r, src);
    if (is_statement and flipped.items.len > 0) {
        try r.signals.append(r.a(), .{
            .source = src,
            .confidence = .high,
            .event_kind = events.ev_restoration,
            .identity = "statement_restored",
            .title = try std.fmt.allocPrint(r.a(), "{s}: restoration language detected", .{src.label}),
            .url = src.url,
            .detail = try std.mem.join(r.a(), ", ", flipped.items),
        });
    } else {
        const identity = try std.fmt.allocPrint(r.a(), "{s}_change:{s}", .{ if (is_statement) "statement" else "keyword", src.id });
        try r.signals.append(r.a(), .{
            .source = src,
            .confidence = .advisory,
            .event_kind = events.ev_advisory,
            .identity = identity,
            .title = try std.fmt.allocPrint(r.a(), "{s}: watched context shifted", .{src.label}),
            .url = src.url,
            .detail = hex,
        });
    }
}

const FrResponse = struct { results: []FrDoc = &.{} };
const FrDoc = struct {
    document_number: ?[]const u8 = null,
    title: ?[]const u8 = null,
    abstract: ?[]const u8 = null,
    publication_date: ?[]const u8 = null,
    filed_at: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
};
fn str(o: ?[]const u8) []const u8 {
    return o orelse "";
}

/// Federal Register documents + public-inspection documents. New documents are
/// recorded; a post-fetch relevance filter (title + abstract against the match
/// set) decides whether one is high-signal. Relevant docs emit an advisory keyed
/// on the document number, so the same doc seen on multiple FR feeds coalesces.
fn detectFederalRegister(r: *Run, src: Source, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(FrResponse, r.a(), body, .{ .ignore_unknown_fields = true }) catch |err| {
        log("source '{s}': JSON parse failed ({s})", .{ src.id, @errorName(err) });
        return error.FetchFailed;
    };
    defer parsed.deinit();

    var new_count: usize = 0;
    for (parsed.value.results) |doc| {
        const num = str(doc.document_number);
        if (num.len == 0) continue;
        if (r.prev.hasSeen(num)) continue;
        r.seen.append(r.a(), r.a().dupe(u8, num) catch num) catch {};
        new_count += 1;

        const title = str(doc.title);
        const haystack = try std.ascii.allocLowerString(r.a(), try std.fmt.allocPrint(r.a(), "{s} {s}", .{ title, str(doc.abstract) }));
        // Tightened relevance: a document must name Anthropic or a specific
        // model, not merely contain a bare keyword like "fable".
        const relevant = html.containsAny(haystack, &sources_mod.strong_terms);
        const pub_date = if (str(doc.publication_date).len > 0) str(doc.publication_date) else str(doc.filed_at);

        try r.ctx.record(.{
            .source_id = src.id,
            .source_label = src.label,
            .source_kind = src.kind.logName(),
            .event = if (relevant) events.ev_relevant_document else events.ev_new_document,
            .tier = src.tier.int(),
            .document_number = num,
            .title = title,
            .publication_date = pub_date,
            .url = str(doc.html_url),
            .published_at = pub_date,
            .published_epoch_ms = events.epochMsFromIso(pub_date) orelse 0,
        });

        if (relevant) {
            markChanged(r, src);
            try r.signals.append(r.a(), .{
                .source = src,
                .confidence = .advisory,
                .event_kind = events.ev_relevant_document,
                .identity = try std.fmt.allocPrint(r.a(), "fr_doc:{s}", .{num}),
                .title = title,
                .document_number = num,
                .url = str(doc.html_url),
                .publication_date = pub_date,
                .published_epoch_ms = events.epochMsFromIso(pub_date) orelse 0,
            });
        }
    }
    if (new_count == 0) log("source '{s}': no new documents", .{src.id});
}

/// RSS / Atom / sitemap. New entries (by guid/link/loc) whose title or key
/// matches the source's terms emit an advisory. The first poll of a source
/// baselines its entire current backlog without alerting.
fn detectFeed(r: *Run, src: Source, body: []const u8) !void {
    const entries = try feed.parse(r.a(), body);
    const first_poll = r.prev.statusFor(src.id) == null and !feedHasAny(r.prev, src.id);

    var new_count: usize = 0;
    for (entries) |e| {
        if (r.prev.feedHasSeen(src.id, e.key)) continue;
        if (alreadyQueued(r, src.id, e.key)) continue;
        r.feeds.append(r.a(), .{ .id = src.id, .key = e.key }) catch {};
        new_count += 1;
        if (first_poll) continue; // baseline: record the backlog, do not alert

        const hay = try std.ascii.allocLowerString(r.a(), try std.fmt.allocPrint(r.a(), "{s} {s}", .{ e.title, e.key }));
        if (!html.containsAny(hay, src.match)) continue;

        markChanged(r, src);
        try r.ctx.record(.{
            .source_id = src.id,
            .source_label = src.label,
            .source_kind = src.kind.logName(),
            .event = events.ev_advisory,
            .tier = src.tier.int(),
            .title = e.title,
            .url = e.key,
            .publication_date = e.published,
            .published_at = e.published,
            .published_epoch_ms = events.epochMsFromIso(e.published) orelse 0,
        });
        try r.signals.append(r.a(), .{
            .source = src,
            .confidence = .advisory,
            .event_kind = events.ev_advisory,
            .identity = try std.fmt.allocPrint(r.a(), "feed:{s}", .{e.key}),
            .title = e.title,
            .url = e.key,
            .publication_date = e.published,
            .published_epoch_ms = events.epochMsFromIso(e.published) orelse 0,
        });
    }
    if (first_poll) log("source '{s}': feed baseline ({d} entries)", .{ src.id, new_count });
}

fn feedHasAny(prev: State, source_id: []const u8) bool {
    for (prev.feed_seen) |f| if (std.mem.eql(u8, f.id, source_id)) return true;
    return false;
}

fn alreadyQueued(r: *Run, source_id: []const u8, key: []const u8) bool {
    for (r.feeds.items) |f| {
        if (std.mem.eql(u8, f.id, source_id) and std.mem.eql(u8, f.key, key)) return true;
    }
    return false;
}

/// Prediction-market state. Advisory only: we record last price and flag a
/// meaningful move, whose purpose is to reveal that a faster source exists than
/// our own coverage (a coverage-gap signal), never to auto-action.
fn detectMarket(r: *Run, src: Source, body: []const u8) !void {
    const price = extractMarketPrice(body) orelse {
        log("source '{s}': no parseable market price", .{src.id});
        return;
    };
    var pbuf: [32]u8 = undefined;
    const price_str = try std.fmt.bufPrint(&pbuf, "{d:.4}", .{price});
    const price_owned = try r.a().dupe(u8, price_str);
    r.hashes.append(r.a(), .{ .id = src.id, .hash = price_owned }) catch {};

    try r.ctx.record(.{
        .source_id = src.id,
        .source_label = src.label,
        .source_kind = src.kind.logName(),
        .event = events.ev_market,
        .tier = src.tier.int(),
        .url = src.url,
        .detail = price_owned,
    });

    if (r.prev.hashFor(src.id)) |old_str| {
        const old = std.fmt.parseFloat(f64, old_str) catch return;
        if (@abs(price - old) >= 0.10) { // 10-point move on a 0..1 probability
            markChanged(r, src);
            try r.signals.append(r.a(), .{
                .source = src,
                .confidence = .advisory,
                .event_kind = events.ev_advisory,
                .identity = try std.fmt.allocPrint(r.a(), "market:{s}", .{src.id}),
                .title = try std.fmt.allocPrint(r.a(), "{s}: market moved {s} -> {s}", .{ src.label, old_str, price_owned }),
                .url = src.url,
                .detail = price_owned,
            });
        }
    }
}

/// Pull a probability/price out of a market JSON response. Tolerant: looks for a
/// `"price"` or `"p"` numeric field anywhere in the body.
fn extractMarketPrice(body: []const u8) ?f64 {
    inline for (.{ "\"price\"", "\"p\"", "\"lastPrice\"" }) |needle| {
        if (std.mem.indexOf(u8, body, needle)) |k| {
            var i = k + needle.len;
            while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '"')) i += 1;
            var j = i;
            while (j < body.len and (std.ascii.isDigit(body[j]) or body[j] == '.' or body[j] == '-')) j += 1;
            if (j > i) {
                if (std.fmt.parseFloat(f64, body[i..j]) catch null) |v| return v;
            }
        }
    }
    return null;
}

fn markChanged(r: *Run, src: Source) void {
    r.ctx.changed = true;
    // Stamp the source's last-change time by rewriting its status record.
    for (r.statuses.items) |*s| {
        if (std.mem.eql(u8, s.id, src.id)) {
            s.last_change_ms = r.ctx.epoch_ms;
            return;
        }
    }
}

// --- trip resolution (coalesce + confidence + emit) -------------------------

const Group = struct {
    identity: []const u8,
    confidence: Confidence,
    members: std.ArrayList(Signal) = .empty,
    distinct_sources: usize = 0,
};

/// Coalesce signals by identity, decide effective confidence (a tier-2/3
/// advisory is promoted to high when corroborated by a second distinct source
/// or a tier-1 signal on the same identity), and emit one alert per new
/// identity with alert-once idempotency and escalation.
fn resolveTrips(r: *Run) !void {
    var groups: std.ArrayList(Group) = .empty;
    for (r.signals.items) |sig| {
        const g = findGroup(&groups, sig.identity) orelse blk: {
            try groups.append(r.a(), .{ .identity = sig.identity, .confidence = .advisory });
            break :blk &groups.items[groups.items.len - 1];
        };
        try g.members.append(r.a(), sig);
        if (sig.confidence == .high) g.confidence = .high;
        if (!groupHasSource(g, sig.source.id)) g.distinct_sources += 1;
    }

    for (groups.items) |*g| {
        try emitGroup(r, g, effectiveConfidence(g.confidence, g.distinct_sources));
    }
}

/// A group's effective confidence: an inherently high signal stays high; an
/// advisory is promoted to high when corroborated by a second distinct source
/// on the same event identity. (A tier-1 signal arrives as `base == .high`.)
fn effectiveConfidence(base: Confidence, distinct_sources: usize) Confidence {
    if (base == .high or distinct_sources >= 2) return .high;
    return .advisory;
}

fn findGroup(groups: *std.ArrayList(Group), identity: []const u8) ?*Group {
    for (groups.items) |*g| {
        if (std.mem.eql(u8, g.identity, identity)) return g;
    }
    return null;
}

fn groupHasSource(g: *Group, id: []const u8) bool {
    for (g.members.items) |m| if (std.mem.eql(u8, m.source.id, id)) return true;
    return false;
}

/// Emit a brand-new coalesced trip. An already-alerted identity is idempotent
/// (returns without re-firing); escalation of a persisting trip is handled
/// separately in `escalateStale`, driven by the alert records rather than a
/// re-appearing signal.
fn emitGroup(r: *Run, g: *Group, effective: Confidence) !void {
    if (r.prev.alertFor(g.identity) != null) return; // alert-once

    const lead = g.members.items[0];
    const tier = bestTier(g);

    var srcs: std.ArrayList([]const u8) = .empty;
    for (g.members.items) |m| {
        if (!csvHas(srcs.items, m.source.id)) srcs.append(r.a(), m.source.id) catch {};
    }

    // Record the audit-log event for the coalesced trip.
    try r.ctx.record(.{
        .source_id = lead.source.id,
        .source_label = lead.source.label,
        .source_kind = lead.source.kind.logName(),
        .event = lead.event_kind,
        .tier = tier,
        .confidence = @tagName(effective),
        .event_identity = g.identity,
        .document_number = lead.document_number,
        .title = lead.title,
        .publication_date = lead.publication_date,
        .url = lead.url,
        .detail = lead.detail,
        .published_at = lead.publication_date,
        .published_epoch_ms = lead.published_epoch_ms,
    });

    try emitEvent(r, .{
        .event_id = g.identity,
        .kind = lead.event_kind,
        .tier = tier,
        .confidence = @tagName(effective),
        .escalation = false,
        .sources = srcs.items,
        .title = lead.title,
        .url = lead.url,
        .document_number = lead.document_number,
        .detail = lead.detail,
    });
    if (effective == .high) notify(r, lead.title, g.identity, lead.url, false);
    r.ctx.changed = true;

    r.alerts.append(r.a(), .{
        .event_identity = g.identity,
        .epoch_ms = r.ctx.epoch_ms,
        .tier = tier,
        .ev_kind = lead.event_kind,
        .title = lead.title,
        .url = lead.url,
    }) catch {};
}

/// Escalation pass: re-fire any tier-1 alert that has gone unacknowledged past
/// the configured window and has not already escalated. Driven by the persisted
/// alert records, so a decisive trip whose underlying signal does not re-appear
/// (a model that stays present, a statement that stays changed) still escalates.
fn escalateStale(r: *Run) void {
    for (r.alerts.items) |*al| {
        if (al.tier != 1 or al.acknowledged or al.escalated) continue;
        // Only alerts that predate this run can escalate; one fired this poll
        // (epoch_ms == now) must not escalate in the same poll it tripped.
        if (al.epoch_ms >= r.ctx.epoch_ms) continue;
        const age_ms = r.ctx.epoch_ms - al.epoch_ms;
        if (age_ms < @as(i64, r.opts.escalate_after_s) * 1000) continue;

        emitEvent(r, .{
            .event_id = al.event_identity,
            .kind = al.ev_kind,
            .tier = al.tier,
            .confidence = "high",
            .escalation = true,
            .sources = &.{},
            .title = al.title,
            .url = al.url,
            .document_number = "",
            .detail = "",
        }) catch {};
        notify(r, al.title, al.event_identity, al.url, true);
        al.escalated = true;
        r.ctx.changed = true;
        log("escalated unacknowledged tier-1 alert '{s}' (age {d}s)", .{ al.event_identity, @divFloor(age_ms, 1000) });
    }
}

fn bestTier(g: *Group) u8 {
    var best: u8 = 3;
    for (g.members.items) |m| {
        if (m.source.tier.int() < best) best = m.source.tier.int();
    }
    return best;
}

const EventFields = struct {
    event_id: []const u8,
    kind: []const u8,
    tier: u8,
    confidence: []const u8,
    escalation: bool,
    sources: []const []const u8,
    title: []const u8,
    url: []const u8,
    document_number: []const u8,
    detail: []const u8,
};

/// Build and emit the single-line structured JSON event to the configured sinks
/// (always stdout; optionally an append-file and a webhook). This is the
/// integration point a downstream execution system consumes.
fn emitEvent(r: *Run, f: EventFields) !void {
    const Emit = struct {
        schema: []const u8,
        event_id: []const u8,
        kind: []const u8,
        tier: u8,
        confidence: []const u8,
        escalation: bool,
        corroborating_sources: []const []const u8,
        detected_at: []const u8,
        epoch_ms: i64,
        title: []const u8,
        evidence_url: []const u8,
        document_number: []const u8,
        detail: []const u8,
    };
    const payload = Emit{
        .schema = "fable-monitor.event/1",
        .event_id = f.event_id,
        .kind = f.kind,
        .tier = f.tier,
        .confidence = f.confidence,
        .escalation = f.escalation,
        .corroborating_sources = f.sources,
        .detected_at = r.ctx.observed_at,
        .epoch_ms = r.ctx.epoch_ms,
        .title = f.title,
        .evidence_url = f.url,
        .document_number = f.document_number,
        .detail = f.detail,
    };
    const line = try std.json.Stringify.valueAlloc(r.a(), payload, .{});

    // Always to stdout (the default sink).
    var buf: [256]u8 = undefined;
    var fw = Io.File.stdout().writer(r.ctx.io, &buf);
    fw.interface.writeAll(line) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.interface.flush() catch {};

    if (r.opts.event_sink_path) |path| appendLine(r, path, line);
    if (r.opts.webhook_url) |url| fetch.postJson(r.ctx, url, line);
}

fn appendLine(r: *Run, path: []const u8, line: []const u8) void {
    const existing = Io.Dir.cwd().readFileAlloc(r.ctx.io, path, r.a(), .limited(64 * 1024 * 1024)) catch "";
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(r.a(), existing) catch return;
    if (existing.len > 0 and existing[existing.len - 1] != '\n') out.append(r.a(), '\n') catch {};
    out.appendSlice(r.a(), line) catch return;
    out.append(r.a(), '\n') catch {};
    // Staged-and-renamed so a crash mid-write cannot tear the sink file.
    events.writeFileAtomic(r.ctx.io, r.a(), path, out.items) catch |err| {
        log("error: failed to write event sink {s}: {s}", .{ path, @errorName(err) });
    };
}

/// Fire the portable shell notify hook (FABLE_MONITOR_NOTIFY). The alert text
/// arrives as $1. Used for high-confidence trips and escalations.
fn notify(r: *Run, title: []const u8, identity: []const u8, url: []const u8, escalate: bool) void {
    const cmd = r.ctx.notify_cmd orelse return;
    const tag = if (escalate) "ESCALATION" else "RESTORATION";
    const message = std.fmt.allocPrint(r.a(), "[{s}] {s} ({s}) {s}", .{ tag, title, identity, url }) catch return;
    const argv = [_][]const u8{ "sh", "-c", cmd, "fable-monitor", message };
    _ = std.process.run(r.a(), r.ctx.io, .{ .argv = &argv }) catch |err| {
        log("notify hook failed: {s}", .{@errorName(err)});
    };
}

fn csvHas(items: []const []const u8, id: []const u8) bool {
    for (items) |i| if (std.mem.eql(u8, i, id)) return true;
    return false;
}

// --- coverage audit / acknowledge / preflight ------------------------------

/// `fable-monitor audit`: print each source's last successful fetch and last
/// detected change, so a quietly dead source is visible before it costs an
/// event. Reads state only.
pub fn audit(ctx: *Context, opts: Options) !void {
    const cfg = config.load(ctx, .{ .sources_path = opts.sources_path });
    const st = state_mod.loadState(ctx) catch State{};
    const now = ctx.epoch_ms;

    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(ctx.io, &buf);
    const out = &fw.interface;
    try out.print("coverage audit @ {s}\n", .{ctx.observed_at});
    try out.print("{s:<34} {s:<5} {s:<8} {s:<14} {s}\n", .{ "source", "tier", "enabled", "last_success", "last_change" });
    for (cfg.sources) |src| {
        const s = st.statusFor(src.id);
        const ls = if (s) |x| agoText(ctx.arena, now, x.last_success_ms) else "never";
        const lc = if (s) |x| agoText(ctx.arena, now, x.last_change_ms) else "never";
        try out.print("{s:<34} {d:<5} {s:<8} {s:<14} {s}\n", .{
            src.id, src.tier.int(), if (src.enabled) "yes" else "no", ls, lc,
        });
    }
    try out.flush();
}

/// Render a real elapsed duration ("42s", "5m3s", "2h10m", "3d4h") into the
/// run arena, which outlives the audit table's printing.
fn agoText(arena: Allocator, now_ms: i64, then_ms: i64) []const u8 {
    if (then_ms == 0) return "never";
    const secs: u64 = @intCast(@max(0, @divFloor(now_ms - then_ms, 1000)));
    if (secs < 60) return std.fmt.allocPrint(arena, "{d}s", .{secs}) catch "?";
    if (secs < 3600) return std.fmt.allocPrint(arena, "{d}m{d}s", .{ secs / 60, secs % 60 }) catch "?";
    if (secs < 86400) return std.fmt.allocPrint(arena, "{d}h{d}m", .{ secs / 3600, (secs % 3600) / 60 }) catch "?";
    return std.fmt.allocPrint(arena, "{d}d{d}h", .{ secs / 86400, (secs % 86400) / 3600 }) catch "?";
}

/// `fable-monitor ack <identity>`: mark a fired alert acknowledged so it stops
/// escalating. The identity is the structured event's `event_id`.
pub fn acknowledge(ctx: *Context, identity: []const u8) !void {
    // Same exclusion as `run`: an ack racing a poll must not be lost.
    var state_lock = try state_mod.acquireLock(ctx);
    defer state_lock.release(ctx.io);

    const st = state_mod.loadState(ctx) catch {
        log("no state to acknowledge against", .{});
        return;
    };
    var found = false;
    for (st.alerts) |*al| {
        if (std.mem.eql(u8, al.event_identity, identity)) {
            al.acknowledged = true;
            found = true;
        }
    }
    if (!found) {
        log("no alert with identity '{s}'", .{identity});
        return;
    }
    try state_mod.saveState(ctx, st);
    log("acknowledged '{s}'", .{identity});
}

/// `fable-monitor preflight`: verify the runtime is ready before the first poll.
/// Checks the two external binaries, write access to the state path, network
/// egress to each enabled source, and the presence of any required secrets.
/// Prints a single clear summary; returns an error if a hard requirement fails.
pub fn preflight(ctx: *Context, opts: Options) !void {
    const cfg = config.load(ctx, .{
        .sources_path = opts.sources_path,
        .only_csv = opts.only_csv,
        .disable_csv = opts.disable_csv,
    });
    var ok = true;

    // External binaries.
    inline for (.{ "curl", "zstd" }) |bin| {
        const present = fetch.toolAvailable(ctx, bin);
        log("preflight: {s} {s}", .{ bin, if (present) "found" else "MISSING" });
        if (!present) ok = false;
    }

    // State path writable.
    const probe = std.fmt.allocPrint(ctx.arena, "{s}.preflight", .{ctx.state_path}) catch ctx.state_path;
    if (Io.Dir.cwd().createFile(ctx.io, probe, .{})) |f| {
        var ff = f;
        ff.close(ctx.io);
        Io.Dir.cwd().deleteFile(ctx.io, probe) catch {};
        log("preflight: state path writable ({s})", .{ctx.state_path});
    } else |err| {
        log("preflight: state path NOT writable ({s}): {s}", .{ ctx.state_path, @errorName(err) });
        ok = false;
    }

    // Secrets: warn (not fatal) when an emitter/heartbeat is unconfigured.
    if (opts.webhook_url == null) log("preflight: FABLE_MONITOR_WEBHOOK unset (structured events go to stdout only)", .{});
    if (opts.heartbeat_url == null) log("preflight: FABLE_MONITOR_HEARTBEAT_URL unset (dead-man's switch disabled)", .{});
    if (ctx.notify_cmd != null) log("preflight: notify hook configured", .{}) else log("preflight: FABLE_MONITOR_NOTIFY unset (no push)", .{});

    const has_api_key = if (opts.anthropic_api_key) |k| k.len > 0 else false;
    if (!has_api_key) log("preflight: ANTHROPIC_API_KEY unset (api_probe sources are skipped)", .{});

    // Network egress per enabled source (HEAD-ish GET; failure is a warning, a
    // single source must not block startup, but report it loudly).
    for (cfg.sources) |src| {
        if (!src.enabled) continue;
        // Don't probe the API without a key: it would 401 and read as a false
        // egress failure. Report it as skipped instead.
        if (src.kind == .api_probe and !has_api_key) {
            log("preflight: egress to '{s}' skipped (ANTHROPIC_API_KEY unset)", .{src.id});
            continue;
        }
        if (src.kind == .market_watch and std.mem.indexOf(u8, src.url, "PLACEHOLDER") != null) {
            log("preflight: hint: source '{s}' URL contains PLACEHOLDER; set a real market id in the sources config", .{src.id});
        }
        const api_key: ?[]const u8 = if (src.kind == .api_probe) opts.anthropic_api_key else null;
        const resp = fetch.fetchConditional(ctx, src.url, "", "", api_key) catch {
            log("preflight: egress to '{s}' FAILED ({s})", .{ src.id, src.url });
            continue;
        };
        log("preflight: egress to '{s}' ok (HTTP {d})", .{ src.id, resp.status });
    }

    if (!ok) {
        log("preflight: FAILED (see MISSING/NOT items above)", .{});
        return error.PreflightFailed;
    }
    log("preflight: ok", .{});
}

const testing = std.testing;

test "extractMarketPrice finds a price field" {
    try testing.expectEqual(@as(f64, 0.42), extractMarketPrice("{\"market\":\"x\",\"price\":0.42}").?);
    try testing.expectEqual(@as(f64, 0.9), extractMarketPrice("[{\"p\": 0.9 }]").?);
    try testing.expect(extractMarketPrice("{\"nope\":1}") == null);
}

test "str coalesces a null FR field to empty" {
    try testing.expectEqualStrings("", str(null));
    try testing.expectEqualStrings("x", str("x"));
}

test "a /v1/models JSON body reveals a controlled model id (api_probe detection)" {
    // Mirrors detectModelList's core: normalize the fetched body, then substring
    // match the (lowercased) controlled ids. The api_probe kind reuses exactly
    // this path against the Anthropic /v1/models JSON.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const present = "{\"data\":[{\"id\":\"claude-fable-5\",\"type\":\"model\"},{\"id\":\"claude-opus-4\",\"type\":\"model\"}]}";
    const absent = "{\"data\":[{\"id\":\"claude-opus-4\",\"type\":\"model\"},{\"id\":\"claude-haiku-4\",\"type\":\"model\"}]}";

    const t_present = try html.normalizeHtml(a, present);
    const t_absent = try html.normalizeHtml(a, absent);
    try testing.expect(std.mem.indexOf(u8, t_present, "claude-fable-5") != null);
    try testing.expect(std.mem.indexOf(u8, t_absent, "claude-fable-5") == null);
}

// Build a minimal Context for detector-path tests: those paths never touch
// io / paths, only the arena, timestamps, and the event list.
fn testContext(arena: Allocator, epoch_ms: i64) Context {
    return .{
        .io = undefined,
        .arena = arena,
        .state_path = "",
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "2026-07-04T00:00:00Z",
        .epoch_ms = epoch_ms,
    };
}

test "a transient fetch failure keeps the baseline so the trip still fires" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 1_000);

    const src = Source{
        .id = "anthropic_statement",
        .kind = .statement_watch,
        .tier = .tier1,
        .url = "https://example.com/statement",
        .label = "Statement",
        .match = &.{"fable"},
        .poll = .fast,
    };
    const suspended = "<p>fable 5 access is suspended pending export review</p>";
    const restored_page = "<p>fable 5 access is restored effective immediately</p>";

    // Poll 1: baseline records the suspended fingerprint, no signal.
    var r1 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };
    recordStatus(&r1, src, true);
    try detectKeywordOrStatement(&r1, src, suspended, true);
    try testing.expectEqual(@as(usize, 0), r1.signals.items.len);
    const st1 = State{
        .version = state_mod.current_version,
        .keyword_hashes = r1.hashes.items,
        .terms_present = r1.terms.items,
        .source_status = r1.statuses.items,
    };
    try testing.expect(st1.hashFor(src.id) != null);

    // Poll 2: the fetch fails; the failure path must carry the baseline.
    var r2 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = st1 };
    handlePollFailure(&r2, src);
    const st2 = State{
        .version = state_mod.current_version,
        .keyword_hashes = r2.hashes.items,
        .terms_present = r2.terms.items,
        .source_status = r2.statuses.items,
    };
    try testing.expectEqualStrings(st1.hashFor(src.id).?, st2.hashFor(src.id).?);

    // Poll 3: the restored page trips against the carried baseline. Without
    // the carry-forward, poll 2 would have dropped the hash and this poll
    // would silently re-baseline instead.
    var r3 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = st2 };
    recordStatus(&r3, src, true);
    try detectKeywordOrStatement(&r3, src, restored_page, true);
    try testing.expectEqual(@as(usize, 1), r3.signals.items.len);
    try testing.expectEqual(Confidence.high, r3.signals.items[0].confidence);
    try testing.expectEqualStrings("statement_restored", r3.signals.items[0].identity);
}

test "statement_watch trips only on an absent-to-present term transition" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 1_000);

    const src = Source{
        .id = "anthropic_statement",
        .kind = .statement_watch,
        .tier = .tier1,
        .url = "https://example.com/statement",
        .label = "Statement",
        .match = &.{ "fable", "available", "return", "restored" },
        .poll = .fast,
    };
    const suspended = "<p>Access to Fable 5 remains suspended pending review.</p>";
    const negated = "<p>Claude Fable 5 is not available. Access will return when authorized.</p>";
    const restored_page = "<p>Access to Fable 5 has been restored for all customers.</p>";

    // Poll 1: baseline. The suspended copy carries no (un-negated) restoration
    // terms, so the persisted term baseline is empty.
    var r1 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };
    recordStatus(&r1, src, true);
    try detectKeywordOrStatement(&r1, src, suspended, true);
    try testing.expectEqual(@as(usize, 0), r1.signals.items.len);
    try testing.expectEqual(@as(usize, 0), r1.terms.items.len);
    const st1 = State{
        .version = state_mod.current_version,
        .keyword_hashes = r1.hashes.items,
        .terms_present = r1.terms.items,
        .source_status = r1.statuses.items,
    };

    // Poll 2: the hash changes but every term hit sits in a negation context
    // ("not available", "will return when ..."). Under the old "hash changed
    // AND term present" semantics this tripped high; now it is advisory only,
    // and the negated hits never persist as present.
    var r2 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = st1 };
    recordStatus(&r2, src, true);
    try detectKeywordOrStatement(&r2, src, negated, true);
    try testing.expectEqual(@as(usize, 1), r2.signals.items.len);
    try testing.expectEqual(Confidence.advisory, r2.signals.items[0].confidence);
    try testing.expectEqualStrings("statement_change:anthropic_statement", r2.signals.items[0].identity);
    try testing.expectEqual(@as(usize, 0), r2.terms.items.len);
    const st2 = State{
        .version = state_mod.current_version,
        .keyword_hashes = r2.hashes.items,
        .terms_present = r2.terms.items,
        .source_status = r2.statuses.items,
    };

    // Poll 3: "restored" flips absent-to-present against the baseline: the
    // decisive high-confidence trip, carrying the flipped terms as detail.
    var r3 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = st2 };
    recordStatus(&r3, src, true);
    try detectKeywordOrStatement(&r3, src, restored_page, true);
    try testing.expectEqual(@as(usize, 1), r3.signals.items.len);
    try testing.expectEqual(Confidence.high, r3.signals.items[0].confidence);
    try testing.expectEqualStrings("statement_restored", r3.signals.items[0].identity);
    try testing.expect(std.mem.indexOf(u8, r3.signals.items[0].detail, "restored") != null);
}

test "a term already present at baseline cannot trip on an unrelated change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 1_000);

    const src = Source{
        .id = "anthropic_statement",
        .kind = .statement_watch,
        .tier = .tier1,
        .url = "https://example.com/statement",
        .label = "Statement",
        .match = &.{ "fable", "available" },
        .poll = .fast,
    };
    // "available" is genuinely present (un-negated) from the very first poll.
    const v1 = "<p>Fable 5 was available to enterprise customers.</p>";
    const v2 = "<p>Fable 5 was available to enterprise customers before the review began.</p>";

    var r1 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };
    recordStatus(&r1, src, true);
    try detectKeywordOrStatement(&r1, src, v1, true);
    try testing.expectEqual(@as(usize, 1), r1.terms.items.len);
    try testing.expectEqualStrings("available", r1.terms.items[0].term);
    const st1 = State{
        .version = state_mod.current_version,
        .keyword_hashes = r1.hashes.items,
        .terms_present = r1.terms.items,
        .source_status = r1.statuses.items,
    };

    // The copy changes but "available" was present at baseline: no transition,
    // so the change is advisory, never the statement_restored trip.
    var r2 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = st1 };
    recordStatus(&r2, src, true);
    try detectKeywordOrStatement(&r2, src, v2, true);
    try testing.expectEqual(@as(usize, 1), r2.signals.items.len);
    try testing.expectEqual(Confidence.advisory, r2.signals.items[0].confidence);
}

test "a pre-v3 state re-baselines statement terms without tripping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 1_000);

    const src = Source{
        .id = "anthropic_statement",
        .kind = .statement_watch,
        .tier = .tier1,
        .url = "https://example.com/statement",
        .label = "Statement",
        .match = &.{ "fable", "restored" },
        .poll = .fast,
    };
    // A v2 state file carried a hash and a status but no term records, so a
    // transition against it is unknowable: even restoration copy plus a hash
    // change must only re-baseline the terms and raise an advisory.
    const prev = State{
        .version = 2,
        .keyword_hashes = @constCast(&[_]State.KeywordHash{
            .{ .id = "anthropic_statement", .hash = "deadbeefdeadbeef" },
        }),
        .source_status = @constCast(&[_]State.SourceStatus{
            .{ .id = "anthropic_statement", .last_poll_ms = 500, .last_success_ms = 500 },
        }),
    };

    var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = prev };
    recordStatus(&r, src, true);
    try detectKeywordOrStatement(&r, src, "<p>Access to Fable 5 has been restored.</p>", true);
    try testing.expectEqual(@as(usize, 1), r.signals.items.len);
    try testing.expectEqual(Confidence.advisory, r.signals.items[0].confidence);
    // The term set is baselined now, so the *next* poll can trust transitions.
    try testing.expectEqual(@as(usize, 1), r.terms.items.len);
    try testing.expectEqualStrings("restored", r.terms.items[0].term);
}

test "model_list_probe ignores an identifier mentioned in suspension copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 1_000);

    const src = Source{
        .id = "anthropic_pricing",
        .kind = .model_list_probe,
        .tier = .tier1,
        .url = "https://example.com/pricing",
        .label = "Pricing",
        .match = &.{"claude-fable-5"},
        .poll = .fast,
    };
    const absent = "<ul><li>claude-opus-4-8</li></ul>";
    const mention = "<ul><li>claude-opus-4-8</li></ul><p>claude-fable-5 remains restricted.</p>";
    const listed = "<ul><li>claude-opus-4-8</li><li>claude-fable-5</li></ul>";

    // Baseline: absent.
    var r1 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };
    recordStatus(&r1, src, true);
    try detectModelList(&r1, src, absent);
    const st1 = State{
        .version = state_mod.current_version,
        .model_present = r1.models.items,
        .source_status = r1.statuses.items,
    };

    // A mere mention inside suspension copy neither trips nor records
    // presence (recording it would swallow the later real transition).
    var r2 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = st1 };
    recordStatus(&r2, src, true);
    try detectModelList(&r2, src, mention);
    try testing.expectEqual(@as(usize, 0), r2.signals.items.len);
    try testing.expectEqual(@as(usize, 0), r2.models.items.len);
    const st2 = State{
        .version = state_mod.current_version,
        .model_present = r2.models.items,
        .source_status = r2.statuses.items,
    };

    // The identifier appearing as a clean listing entry still trips high.
    var r3 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = st2 };
    recordStatus(&r3, src, true);
    try detectModelList(&r3, src, listed);
    try testing.expectEqual(@as(usize, 1), r3.signals.items.len);
    try testing.expectEqual(Confidence.high, r3.signals.items[0].confidence);
    try testing.expectEqualStrings("model_present:claude-fable-5", r3.signals.items[0].identity);
}

test "recordStatus replaces an earlier record for the same source" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = testContext(arena_state.allocator(), 5_000);

    const src = Source{ .id = "fr_bis", .kind = .federal_register, .tier = .tier2, .url = "", .label = "" };
    var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };

    // Fetch succeeded, a change was stamped, then the detector failed: the
    // run must persist exactly one record, with the failure disposition (no
    // success stamp resurrected) but the change stamp preserved.
    recordStatus(&r, src, true);
    markChanged(&r, src);
    recordStatus(&r, src, false);
    try testing.expectEqual(@as(usize, 1), r.statuses.items.len);
    const st = r.statuses.items[0];
    try testing.expectEqual(@as(i64, 5_000), st.last_poll_ms);
    try testing.expectEqual(@as(i64, 0), st.last_success_ms); // detector failure wins
    try testing.expectEqual(@as(i64, 5_000), st.last_change_ms); // markChanged survives
}

test "feed seen-set cap is per source: a huge sitemap cannot evict another feed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 0);
    var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };

    // One small feed's keys, then a sitemap baseline far over the cap.
    try r.feeds.append(a, .{ .id = "google_news", .key = "news-old" });
    try r.feeds.append(a, .{ .id = "google_news", .key = "news-new" });
    for (0..max_feed_seen_per_source + 50) |i| {
        const key = try std.fmt.allocPrint(a, "sitemap-{d}", .{i});
        try r.feeds.append(a, .{ .id = "anthropic_sitemap", .key = key });
    }

    const capped = capFeeds(&r, max_feed_seen_per_source);
    const st = State{ .feed_seen = capped };
    // The small feed keeps everything; the big feed keeps only the newest N.
    try testing.expect(st.feedHasSeen("google_news", "news-old"));
    try testing.expect(st.feedHasSeen("google_news", "news-new"));
    try testing.expect(!st.feedHasSeen("anthropic_sitemap", "sitemap-0"));
    try testing.expect(!st.feedHasSeen("anthropic_sitemap", "sitemap-49"));
    try testing.expect(st.feedHasSeen("anthropic_sitemap", "sitemap-50"));
    try testing.expect(st.feedHasSeen("anthropic_sitemap", "sitemap-549"));
    try testing.expectEqual(@as(usize, max_feed_seen_per_source + 2), capped.len);
}

test "agoText renders real durations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base: i64 = 1_000; // then_ms == 0 is the "never polled" sentinel
    try testing.expectEqualStrings("never", agoText(a, base, 0));
    try testing.expectEqualStrings("42s", agoText(a, base + 42_000, base));
    try testing.expectEqualStrings("5m3s", agoText(a, base + 303_000, base));
    try testing.expectEqualStrings("2h10m", agoText(a, base + (2 * 3600 + 10 * 60) * 1000, base));
    try testing.expectEqualStrings("3d4h", agoText(a, base + (3 * 86400 + 4 * 3600) * 1000, base));
    try testing.expectEqualStrings("0s", agoText(a, base, base + 1_000)); // clock skew clamps
}

test "effectiveConfidence promotes corroborated advisories" {
    // A single advisory stays advisory.
    try testing.expectEqual(Confidence.advisory, effectiveConfidence(.advisory, 1));
    // Two distinct sources on one identity promote to high.
    try testing.expectEqual(Confidence.high, effectiveConfidence(.advisory, 2));
    // An inherently high (tier-1) signal stays high regardless of count.
    try testing.expectEqual(Confidence.high, effectiveConfidence(.high, 1));
}
