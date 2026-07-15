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
    /// Maximum observation rows retained by automatic segment compaction.
    max_events: usize = 100_000,
    /// Anthropic API key (ANTHROPIC_API_KEY) for `api_probe` sources. When null
    /// or empty, api_probe sources are skipped (never fetched) so the monitor
    /// runs fine without a key. Never logged; used only as a request header.
    anthropic_api_key: ?[]const u8 = null,
    /// Decisive sources whose persisted successful observation must be fresh.
    required_source_ids: []const []const u8 = &.{},
    /// Minimum number of decisive sources whose persisted success is fresh.
    minimum_decisive_sources: u32 = 1,
};

/// Explicit disposition of one poll. `run` maps degraded/failed to distinct
/// errors so existing command callers propagate both as a nonzero exit.
pub const Outcome = enum { healthy, degraded, failed };

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
    deliveries: std.ArrayList(State.DeliveryRecord) = .empty,
    signals: std.ArrayList(Signal) = .empty,
    polled: std.ArrayList([]const u8) = .empty,
    successful: std.ArrayList([]const u8) = .empty,
    changed_sources: std.ArrayList([]const u8) = .empty,

    // metrics
    total_fetch_ms: i64 = 0,
    n_ok: usize = 0,
    n_304: usize = 0,
    n_fail: usize = 0,
    n_due: usize = 0,
    n_decisive_ok: usize = 0,
    delivery_failed: bool = false,

    fn a(self: *Run) Allocator {
        return self.ctx.arena;
    }

    fn markPolled(self: *Run, id: []const u8) !void {
        try self.polled.append(self.a(), id);
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
        .required_source_ids = opts.required_source_ids,
        .minimum_decisive_sources = opts.minimum_decisive_sources,
    });
    log("fable-monitor polling: {d} sources from {s}", .{ cfg.sources.len, cfg.origin });

    // Serialize the whole read-modify-write against concurrent polls/acks so
    // an overlapping cron tick cannot discard this run's writes (or vice
    // versa). Held until this run's state and log are persisted. A lock we
    // cannot take (contention, or an unwritable/misconfigured state directory)
    // is a closed failure: report it as such and exit nonzero rather than
    // crashing with a raw error, so no run can be silently skipped.
    var state_lock = state_mod.acquireLock(ctx) catch |err| {
        if (err == error.OutOfMemory) return err;
        log("error: could not acquire state lock: {s}", .{@errorName(err)});
        return error.PollFailed;
    };
    var lock_held = true;
    defer if (lock_held) state_lock.release(ctx.io);

    const prev: State = state_mod.loadState(ctx) catch |err| switch (err) {
        error.FileNotFound => .{},
        else => {
            log("error: could not read state: {s}", .{@errorName(err)});
            return error.PollFailed;
        },
    };

    var r = Run{ .ctx = ctx, .opts = opts, .cfg = cfg, .prev = prev };

    // Carry forward the cumulative sets (seen FR docs, seen feed keys) and the
    // alert bookkeeping; per-source records are carried forward later for
    // sources we do not poll this tick.
    for (prev.federal_register_seen) |d| try r.seen.append(r.a(), d);
    for (prev.feed_seen) |f| try r.feeds.append(r.a(), f);
    // Expiry must happen before duplicate suppression, otherwise an occurrence
    // arriving on the expiry poll is incorrectly swallowed by the old episode.
    for (prev.alerts) |al| {
        if (!state_mod.alertExpired(al, ctx.epoch_ms)) try r.alerts.append(r.a(), al);
    }
    for (prev.deliveries) |delivery| try r.deliveries.append(r.a(), delivery);

    const fast_interval = opts.fast_interval_override orelse cfg.fast_interval_s;

    for (cfg.sources) |src| {
        if (!src.enabled) continue;
        if (!isDue(&r, src, fast_interval)) {
            try carryForward(&r, src);
            continue;
        }
        r.n_due += 1;
        // api_probe needs a key: skip gracefully (no fetch, no error) when the
        // key is unset so the build/tests and the keyless poller run fine.
        if (src.kind == .api_probe and !hasApiKey(&r)) {
            log("source '{s}': api_probe skipped (ANTHROPIC_API_KEY unset)", .{src.id});
            if (requiredId(opts.required_source_ids, src.id)) {
                try handlePollFailure(&r, src);
            } else {
                try carryForward(&r, src);
            }
            continue;
        }
        pollOne(&r, src) catch |err| {
            if (err == error.OutOfMemory) return err;
            // Fail closed: one source erroring must not abort the poll.
            log("error: source '{s}' failed: {s}", .{ src.id, @errorName(err) });
            try handlePollFailure(&r, src);
        };
    }

    try rearmEndedEpisodes(&r);

    // Decide alerts from the collected signals (tiered + coalesced), then
    // escalate any decisive alert left unacknowledged past the window.
    try resolveTrips(&r);
    try escalateStale(&r);

    // Persist the audit batch before advancing detector baselines. A log
    // failure therefore cannot make an observed transition disappear from
    // history while state advances past it. External delivery still starts
    // only after the durable outbox state commit below.
    const capped_feeds = try capFeeds(&r, max_feed_seen_per_source);
    const next = State{
        .federal_register_seen = state_mod.capTail(r.seen.items, 300),
        .keyword_hashes = r.hashes.items,
        .validators = r.validators.items,
        .model_present = r.models.items,
        .terms_present = r.terms.items,
        .feed_seen = capped_feeds,
        .source_status = r.statuses.items,
        .alerts = r.alerts.items,
        .deliveries = r.deliveries.items,
    };
    var outcome = classifyOutcome(&r, next);
    events.appendLog(ctx.io, ctx.arena, ctx.log_path, ctx.events.items, opts.max_events) catch |err| {
        log("error: failed to append observation log: {s}", .{@errorName(err)});
        logRunOutcome(&r, .failed, "suppressed", false, false);
        return error.PollFailed;
    };
    state_mod.saveState(ctx, next) catch |err| {
        log("error: failed to persist state: {s}", .{@errorName(err)});
        logRunOutcome(&r, .failed, "suppressed", true, false);
        return error.PollFailed;
    };
    state_lock.release(ctx.io);
    lock_held = false;

    deliverPending(ctx, opts, false, null) catch |err| {
        if (err == error.OutOfMemory) return err;
        r.delivery_failed = true;
        log("delivery backlog remains: {s}", .{@errorName(err)});
        outcome = .failed;
    };

    const wall = Io.Timestamp.now(ctx.io, .real).toMilliseconds() - t_start;
    log("poll metrics: {d} ok, {d} not-modified, {d} failed; fetch {d}ms, wall {d}ms", .{
        r.n_ok, r.n_304, r.n_fail, r.total_fetch_ms, wall,
    });

    // Dead-man's switch: report success only for a healthy, fully persisted run.
    var heartbeat_result: []const u8 = if (opts.heartbeat_url == null) "not-configured" else "suppressed";
    if (outcome == .healthy) {
        if (opts.heartbeat_url) |hb| {
            fetch.pingHeartbeat(ctx, hb) catch |err| {
                log("heartbeat FAILED: {s}", .{@errorName(err)});
                outcome = .degraded;
                heartbeat_result = "failed";
            };
            if (outcome == .healthy) heartbeat_result = "ok";
        }
    }

    logRunOutcome(&r, outcome, heartbeat_result, true, true);

    if (!ctx.changed) log("no changes detected", .{});
    return switch (outcome) {
        .healthy => {},
        .degraded => error.PollDegraded,
        .failed => error.PollFailed,
    };
}

fn classifyOutcome(r: *Run, next: State) Outcome {
    if (!decisiveCoverage(r.cfg, next, r.ctx.epoch_ms, r.opts).healthy) return .failed;
    if (r.n_fail > 0) return .degraded;
    return .healthy;
}

pub const Coverage = struct {
    healthy: bool,
    fresh_decisive: u32,
    required_fresh: bool,
};

/// Health is based on persisted successful observations, not work performed on
/// this scheduler tick. Two missed source intervals exhaust freshness.
pub fn decisiveCoverage(cfg: Config, st: State, now_ms: i64, opts: Options) Coverage {
    var fresh_decisive: u32 = 0;
    var required_fresh = true;
    for (cfg.sources) |src| {
        if (!src.enabled or !src.isDecisive()) continue;
        const interval_s = switch (src.poll) {
            .fast => opts.fast_interval_override orelse cfg.fast_interval_s,
            .slow => cfg.slow_interval_s,
        };
        const fresh = if (st.statusFor(src.id)) |status|
            successFresh(now_ms, status.last_success_ms, @as(i64, interval_s) * 2 * std.time.ms_per_s)
        else
            false;
        if (fresh) fresh_decisive += 1;
        if (requiredId(opts.required_source_ids, src.id) and !fresh) required_fresh = false;
    }
    return .{
        .healthy = required_fresh and fresh_decisive >= opts.minimum_decisive_sources,
        .fresh_decisive = fresh_decisive,
        .required_fresh = required_fresh,
    };
}

fn successFresh(now_ms: i64, success_ms: i64, max_age_ms: i64) bool {
    return success_ms > 0 and success_ms <= now_ms and now_ms - success_ms <= max_age_ms;
}

fn requiredId(ids: []const []const u8, wanted: []const u8) bool {
    for (ids) |id| if (std.mem.eql(u8, id, wanted)) return true;
    return false;
}

fn logRunOutcome(r: *Run, outcome: Outcome, heartbeat: []const u8, audit_persisted: bool, state_persisted: bool) void {
    const delivery_counts = (State{ .deliveries = r.deliveries.items }).deliveryCounts();
    log("poll outcome={s} due={d} ok={d} failed={d} decisive_ok={d} delivery_pending={d} delivery_failed={d} audit_persisted={s} state_persisted={s} delivery={s} heartbeat={s}", .{
        @tagName(outcome),
        r.n_due,
        r.n_ok,
        r.n_fail,
        r.n_decisive_ok,
        delivery_counts.pending,
        delivery_counts.failed,
        if (audit_persisted) "yes" else "no",
        if (state_persisted) "yes" else "no",
        if (r.delivery_failed) "failed" else "ok",
        heartbeat,
    });
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
fn carryForward(r: *Run, src: Source) !void {
    if (!hasValidatorQueued(r, src.id)) {
        if (r.prev.validatorFor(src.id)) |v| try r.validators.append(r.a(), v);
    }
    if (!hasHashQueued(r, src.id)) {
        if (r.prev.hashFor(src.id)) |h| try r.hashes.append(r.a(), .{ .id = src.id, .hash = h });
    }
    if (!hasStatusQueued(r, src.id)) {
        if (r.prev.statusFor(src.id)) |s| try r.statuses.append(r.a(), s);
    }
    if (!hasModelQueued(r, src.id)) {
        for (r.prev.model_present) |m| {
            if (std.mem.eql(u8, m.id, src.id)) try r.models.append(r.a(), m);
        }
    }
    if (!hasTermQueued(r, src.id)) {
        for (r.prev.terms_present) |t| {
            if (std.mem.eql(u8, t.id, src.id)) try r.terms.append(r.a(), t);
        }
    }
}

/// The fail-closed path for a source whose poll errored: count it, stamp the
/// failed attempt, and carry the prior baseline (hash, validators,
/// model_present) forward. Without the carry-forward a transient fetch
/// failure would drop the baseline and the next successful poll would
/// re-baseline instead of tripping.
fn handlePollFailure(r: *Run, src: Source) !void {
    r.n_fail += 1;
    try recordStatus(r, src, false);
    try carryForward(r, src);
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
fn capFeeds(r: *Run, max_per_source: usize) ![]State.FeedSeen {
    const items = r.feeds.items;
    var kept: std.ArrayList(State.FeedSeen) = .empty;
    var counts = std.StringHashMap(usize).init(r.a());
    defer counts.deinit();
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const f = items[i];
        const newer = counts.get(f.id) orelse 0;
        if (newer < max_per_source) try kept.append(r.a(), f);
        try counts.put(f.id, newer +| 1);
    }
    std.mem.reverse(State.FeedSeen, kept.items);
    return kept.items;
}

// --- fetch + dispatch -------------------------------------------------------

fn pollOne(r: *Run, src: Source) !void {
    try r.markPolled(src.id);
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
        try r.validators.append(r.a(), .{ .id = src.id, .etag = resp.etag, .last_modified = resp.last_modified });
    } else if (r.prev.validatorFor(src.id)) |v| {
        try r.validators.append(r.a(), v); // keep prior validators on a 304
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

    if (resp.not_modified) {
        // A 304 cannot establish an initial content baseline.
        if (r.prev.statusFor(src.id) == null) return error.FetchFailed;
        r.n_304 += 1;
        try carryForwardContent(r, src); // unchanged: keep prior hash/models
        try markPollSuccess(r, src);
        log("source '{s}': not modified (304)", .{src.id});
        return;
    }

    switch (src.kind) {
        .model_list_probe, .api_probe => {
            if (src.kind == .api_probe and r.opts.fixtures_dir == null and !isJsonContentType(resp.content_type)) {
                log("source '{s}': expected JSON content type, got '{s}'", .{ src.id, resp.content_type });
                return error.FetchFailed;
            }
            try detectModelList(r, src, resp.body);
        },
        .statement_watch => try detectKeywordOrStatement(r, src, resp.body, true),
        .keyword_watch => try detectKeywordOrStatement(r, src, resp.body, false),
        .federal_register, .federal_register_public_inspection => try detectFederalRegister(r, src, resp.body),
        .feed_watch => try detectFeed(r, src, resp.body),
        .market_watch => try detectMarket(r, src, resp.body),
    }
    try markPollSuccess(r, src);
}

fn isJsonContentType(value: []const u8) bool {
    const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..semicolon], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json") or std.mem.endsWith(u8, media_type, "+json");
}

fn markPollSuccess(r: *Run, src: Source) !void {
    try recordStatus(r, src, true);
    try r.successful.append(r.a(), src.id);
    r.n_ok += 1;
    if (src.isDecisive()) r.n_decisive_ok += 1;
}

/// Keep prior per-source content records when a fetch returned 304.
fn carryForwardContent(r: *Run, src: Source) !void {
    if (r.prev.hashFor(src.id)) |h| try r.hashes.append(r.a(), .{ .id = src.id, .hash = h });
    for (r.prev.model_present) |m| {
        if (std.mem.eql(u8, m.id, src.id)) try r.models.append(r.a(), m);
    }
    for (r.prev.terms_present) |t| {
        if (std.mem.eql(u8, t.id, src.id)) try r.terms.append(r.a(), t);
    }
}

const FetchResult = struct {
    status: u32 = 200,
    body: []u8 = &.{},
    etag: []const u8 = "",
    last_modified: []const u8 = "",
    content_type: []const u8 = "",
    not_modified: bool = false,
    fetch_ms: i64 = 0,
};

/// Fetch a source's body: from a fixture file in test mode, else a conditional
/// HTTP request carrying the persisted validators.
fn fetchSource(r: *Run, src: Source) !FetchResult {
    if (r.opts.fixtures_dir) |dir| {
        const path = try std.fmt.allocPrint(r.a(), "{s}/{s}", .{ dir, src.id });
        const body = Io.Dir.cwd().readFileAlloc(r.ctx.io, path, r.a(), .limited(16 * 1024 * 1024)) catch |err| {
            if (err == error.OutOfMemory) return err;
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
        .content_type = resp.content_type,
        .not_modified = resp.not_modified,
        .fetch_ms = resp.fetch_ms,
    };
}

fn recordStatus(r: *Run, src: Source, success: bool) !void {
    const prev = r.prev.statusFor(src.id);
    var st = State.SourceStatus{
        .id = src.id,
        .last_poll_ms = r.ctx.epoch_ms,
        .last_success_ms = if (prev) |p| p.last_success_ms else 0,
        .last_change_ms = if (prev) |p| p.last_change_ms else 0,
    };
    if (success) st.last_success_ms = r.ctx.epoch_ms;
    if (csvHas(r.changed_sources.items, src.id)) st.last_change_ms = r.ctx.epoch_ms;
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
    try r.statuses.append(r.a(), st);
}

// --- detectors --------------------------------------------------------------

const detector_version = "2";

fn evidenceDetail(arena: Allocator, evidence: []const u8) ![]const u8 {
    const digest = std.hash.Wyhash.hash(0, evidence);
    const excerpt = evidence[0..@min(evidence.len, 160)];
    return std.fmt.allocPrint(arena, "detector={s}; hash={x:0>16}; excerpt={s}", .{ detector_version, digest, excerpt });
}

fn evidenceAround(text: []const u8, needle: []const u8) []const u8 {
    const pos = std.mem.indexOf(u8, text, needle) orelse return text[0..@min(text.len, 160)];
    const lo = pos -| 60;
    return text[lo..@min(text.len, pos + needle.len + 100)];
}

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
/// presence. API responses are parsed as the expected model-list schema and
/// compare only exact `data[].id` values.
fn detectModelList(r: *Run, src: Source, body: []const u8) !void {
    const had_prior = hasPriorModels(r.prev, src.id);
    var api_models: []const ApiModel = &.{};
    const text = if (src.kind == .api_probe) "" else try sources_mod.extractVisibleText(r.a(), body);
    if (src.kind == .api_probe) {
        // Parse into the run arena (r.a()); no owned Parsed wrapper to deinit.
        const decoded = std.json.parseFromSliceLeaky(ApiModelsResponse, r.a(), body, .{ .ignore_unknown_fields = true }) catch |err| {
            if (err == error.OutOfMemory) return err;
            log("source '{s}': model API schema parse failed ({s})", .{ src.id, @errorName(err) });
            return error.FetchFailed;
        };
        api_models = decoded.data;
    }

    for (src.match) |model| {
        const lower = try std.ascii.allocLowerString(r.a(), model);
        const present = switch (src.kind) {
            .model_list_probe => sources_mod.presentExactOutsideNegation(text, lower),
            .api_probe => apiHasExactModel(api_models, model),
            else => unreachable,
        };
        if (!present) continue;

        try r.models.append(r.a(), .{ .id = src.id, .model = model });

        const was_present = r.prev.modelIsPresent(src.id, model);
        if (!was_present and had_prior) {
            // Absent-to-present: the single most decisive confirmation.
            try markChanged(r, src);
            const identity = try std.fmt.allocPrint(r.a(), "model_present:{s}", .{model});
            try r.signals.append(r.a(), .{
                .source = src,
                .confidence = .high,
                .event_kind = events.ev_restoration,
                .identity = identity,
                .title = try std.fmt.allocPrint(r.a(), "Model {s} present in public listing", .{model}),
                .url = src.url,
                .detail = try evidenceDetail(r.a(), if (src.kind == .api_probe) model else evidenceAround(text, lower)),
            });
        }
    }
    if (!had_prior) log("source '{s}': model-list baseline recorded", .{src.id});
}

const ApiModelsResponse = struct { data: []ApiModel };
const ApiModel = struct {
    id: []const u8,
    type: []const u8,
};

fn apiHasExactModel(models: []const ApiModel, wanted: []const u8) bool {
    for (models) |model| {
        if (std.mem.eql(u8, model.type, "model") and std.mem.eql(u8, model.id, wanted)) return true;
    }
    return false;
}

fn hasPriorModels(prev: State, source_id: []const u8) bool {
    // "Prior" means we have polled this source before. A source with a status
    // record but no present models had an all-absent prior reading, which still
    // counts as a baseline for transition detection.
    if (prev.statusFor(source_id)) |status| return status.last_success_ms > 0;
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
    const visible_text = try sources_mod.extractVisibleText(r.a(), body);
    const blob = try html.extractKeywordContext(r.a(), visible_text, src.match);
    const digest = std.hash.Wyhash.hash(0, blob);
    const hex = try std.fmt.allocPrint(r.a(), "{x:0>16}", .{digest});
    try r.hashes.append(r.a(), .{ .id = src.id, .hash = hex });

    // Statement pages persist which restoration terms are present this poll
    // (against the full normalized text, so detection does not depend on the
    // fingerprint's context windows). A flip is only trusted when the prior
    // state actually carried a term baseline: a pre-v3 state file has none,
    // and re-baselining silently beats trusting an unknowable transition.
    var flipped: std.ArrayList([]const u8) = .empty;
    const successful_baseline = if (r.prev.statusFor(src.id)) |status| status.last_success_ms > 0 else false;
    const term_baseline_known = is_statement and
        r.prev.version >= state_mod.term_records_version and
        successful_baseline;
    if (is_statement) {
        const text = visible_text;
        for (sources_mod.restoration_terms) |term| {
            if (!sources_mod.restorationNearModel(text, term)) continue;
            try r.terms.append(r.a(), .{ .id = src.id, .term = term });
            if (term_baseline_known and !r.prev.termIsPresent(src.id, term)) {
                try flipped.append(r.a(), term);
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
            .detail = try evidenceDetail(r.a(), blob),
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

    try markChanged(r, src);
    if (is_statement and flipped.items.len > 0) {
        try r.signals.append(r.a(), .{
            .source = src,
            .confidence = .high,
            .event_kind = events.ev_restoration,
            .identity = "statement_restored",
            .title = try std.fmt.allocPrint(r.a(), "{s}: restoration language detected", .{src.label}),
            .url = src.url,
            .detail = try evidenceDetail(r.a(), evidenceAround(visible_text, flipped.items[0])),
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
            .detail = try evidenceDetail(r.a(), blob),
        });
    }
}

const FrResponse = struct {
    results: ?[]FrDoc = null,
    meta: ?struct { pil_unavailability_message: []const u8 = "" } = null,
};
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
    // Parse into the run arena; no owned Parsed wrapper to deinit.
    const decoded = std.json.parseFromSliceLeaky(FrResponse, r.a(), body, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return err;
        log("source '{s}': JSON parse failed ({s})", .{ src.id, @errorName(err) });
        return error.FetchFailed;
    };

    const results = decoded.results orelse {
        if (decoded.meta) |meta| {
            if (meta.pil_unavailability_message.len > 0) {
                log("source '{s}': public-inspection list temporarily unavailable", .{src.id});
                return error.SourceUnavailable;
            }
        }
        return error.FetchFailed;
    };

    var new_count: usize = 0;
    for (results) |doc| {
        const num = str(doc.document_number);
        if (num.len == 0) continue;
        const stage = federalRegisterStage(src.kind);
        const seen_key = try std.fmt.allocPrint(r.a(), "fr:{s}:{s}", .{ stage, num });
        if (federalRegisterSeen(r.prev, src.kind, seen_key, num)) continue;
        try r.seen.append(r.a(), seen_key);
        new_count += 1;

        const title = str(doc.title);
        const haystack = try std.ascii.allocLowerString(r.a(), try std.fmt.allocPrint(r.a(), "{s} {s}", .{ title, str(doc.abstract) }));
        // Tightened relevance: a document must name Anthropic or a specific
        // model, not merely contain a bare keyword like "fable".
        const relevant = html.containsAny(haystack, &sources_mod.strong_terms);
        const pub_date = if (str(doc.publication_date).len > 0) str(doc.publication_date) else str(doc.filed_at);
        const detail = try evidenceDetail(r.a(), haystack);

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
            .detail = detail,
        });

        if (relevant) {
            try markChanged(r, src);
            try r.signals.append(r.a(), .{
                .source = src,
                .confidence = .advisory,
                .event_kind = events.ev_relevant_document,
                .identity = try std.fmt.allocPrint(r.a(), "fr_doc:{s}:{s}", .{ stage, num }),
                .title = title,
                .document_number = num,
                .url = str(doc.html_url),
                .publication_date = pub_date,
                .published_epoch_ms = events.epochMsFromIso(pub_date) orelse 0,
                .detail = detail,
            });
        }
    }
    if (new_count == 0) log("source '{s}': no new documents", .{src.id});
}

fn federalRegisterStage(kind: SourceKind) []const u8 {
    return if (kind == .federal_register_public_inspection) "preliminary" else "published";
}

fn federalRegisterSeen(prev: State, kind: SourceKind, stage_key: []const u8, legacy_number: []const u8) bool {
    if (prev.hasSeen(stage_key)) return true;
    // Legacy keys did not carry stage. Preserve PI deduplication, but allow the
    // authoritative publication pass to reevaluate a document first seen there.
    return kind == .federal_register_public_inspection and prev.hasSeen(legacy_number);
}

/// RSS / Atom / sitemap. New entries (by guid/link/loc) whose title or key
/// matches the source's terms emit an advisory. The first poll of a source
/// baselines its entire current backlog without alerting.
fn detectFeed(r: *Run, src: Source, body: []const u8) !void {
    const entries = try feed.parse(r.a(), body);
    const successful_baseline = if (r.prev.statusFor(src.id)) |status| status.last_success_ms > 0 else false;
    const first_poll = !successful_baseline and !feedHasAny(r.prev, src.id);

    var new_count: usize = 0;
    for (entries) |e| {
        if (r.prev.feedHasSeen(src.id, e.key)) continue;
        if (alreadyQueued(r, src.id, e.key)) continue;
        try r.feeds.append(r.a(), .{ .id = src.id, .key = e.key });
        new_count += 1;
        if (first_poll) continue; // baseline: record the backlog, do not alert

        const hay = try std.ascii.allocLowerString(r.a(), try std.fmt.allocPrint(r.a(), "{s} {s}", .{ e.title, e.key }));
        if (!html.containsAny(hay, src.match)) continue;

        try markChanged(r, src);
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

/// A completed absent observation closes the prior restoration episode. Remove
/// its alert record before resolving this poll so a later absent-to-present
/// transition creates a new occurrence instead of being suppressed forever.
fn rearmEndedEpisodes(r: *Run) !void {
    var observed_model_source = false;
    var observed_statement_source = false;
    for (r.cfg.sources) |src| {
        if (!csvHas(r.successful.items, src.id)) continue;
        if (src.kind == .model_list_probe or src.kind == .api_probe) observed_model_source = true;
        if (src.kind == .statement_watch) observed_statement_source = true;
    }

    if (observed_model_source) {
        for (sources_mod.model_ids) |model| {
            var present = false;
            for (r.models.items) |m| {
                if (std.mem.eql(u8, m.model, model)) {
                    present = true;
                    break;
                }
            }
            if (!present) removeAlert(r, try std.fmt.allocPrint(r.a(), "model_present:{s}", .{model}));
        }
    }
    if (observed_statement_source and r.terms.items.len == 0) removeAlert(r, "statement_restored");
}

fn removeAlert(r: *Run, identity: []const u8) void {
    var i: usize = 0;
    while (i < r.alerts.items.len) {
        if (std.mem.eql(u8, r.alerts.items[i].event_identity, identity)) {
            _ = r.alerts.orderedRemove(i);
        } else {
            i += 1;
        }
    }
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
    const old_price = if (r.prev.hashFor(src.id)) |old_str|
        try std.fmt.parseFloat(f64, old_str)
    else
        null;
    try r.hashes.append(r.a(), .{ .id = src.id, .hash = price_owned });

    try r.ctx.record(.{
        .source_id = src.id,
        .source_label = src.label,
        .source_kind = src.kind.logName(),
        .event = events.ev_market,
        .tier = src.tier.int(),
        .url = src.url,
        .detail = price_owned,
    });

    if (old_price) |old| {
        if (@abs(price - old) >= 0.10) { // 10-point move on a 0..1 probability
            const old_str = r.prev.hashFor(src.id).?;
            try markChanged(r, src);
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

fn markChanged(r: *Run, src: Source) !void {
    r.ctx.changed = true;
    if (!csvHas(r.changed_sources.items, src.id)) try r.changed_sources.append(r.a(), src.id);
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
    independent_sources: usize = 0,
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
        if (groupAddsIndependentSource(g, sig.source)) g.independent_sources += 1;
        try g.members.append(r.a(), sig);
        if (sig.confidence == .high) g.confidence = .high;
    }

    for (groups.items) |*g| {
        try emitGroup(r, g, effectiveConfidence(g.confidence, g.independent_sources));
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

fn groupAddsIndependentSource(g: *Group, candidate: Source) bool {
    for (g.members.items) |member| {
        if (!sourcesAreIndependent(member.source, candidate)) return false;
    }
    return true;
}

fn sourcesAreIndependent(a: Source, b: Source) bool {
    if (std.mem.eql(u8, a.id, b.id)) return false;
    // Source notes can explicitly document a separately maintained signal.
    if (containsIgnoreCase(a.lead_time, "independent") or containsIgnoreCase(b.lead_time, "independent")) return true;
    return !sameOperator(a.url, b.url) or !std.mem.eql(u8, contentFamily(a.kind), contentFamily(b.kind));
}

fn contentFamily(kind: SourceKind) []const u8 {
    return switch (kind) {
        .federal_register, .federal_register_public_inspection => "federal-register-document",
        .model_list_probe => "html-model-list",
        .api_probe => "api-model-list",
        .keyword_watch => "keyword-page",
        .statement_watch => "statement-page",
        .feed_watch => "feed",
        .market_watch => "market",
    };
}

fn sameOperator(a_url: []const u8, b_url: []const u8) bool {
    const a = registrableHost(urlHost(a_url));
    const b = registrableHost(urlHost(b_url));
    return a.len > 0 and std.ascii.eqlIgnoreCase(a, b);
}

fn urlHost(url: []const u8) []const u8 {
    const start = if (std.mem.indexOf(u8, url, "://")) |p| p + 3 else 0;
    const rest = url[start..];
    const end = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
    return rest[0..end];
}

fn registrableHost(host: []const u8) []const u8 {
    const last = std.mem.lastIndexOfScalar(u8, host, '.') orelse return host;
    const prior = std.mem.lastIndexOfScalar(u8, host[0..last], '.') orelse return host;
    const suffix = host[last + 1 ..];
    const second_level = host[prior + 1 .. last];
    if (suffix.len == 2 and isCommonSecondLevelDomain(second_level)) {
        const before = std.mem.lastIndexOfScalar(u8, host[0..prior], '.') orelse return host;
        return host[before + 1 ..];
    }
    return host[prior + 1 ..];
}

fn isCommonSecondLevelDomain(label: []const u8) bool {
    inline for (.{ "ac", "co", "com", "gov", "net", "org" }) |common| {
        if (std.ascii.eqlIgnoreCase(label, common)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Emit a brand-new coalesced trip. An already-alerted identity is idempotent
/// (returns without re-firing); escalation of a persisting trip is handled
/// separately in `escalateStale`, driven by the alert records rather than a
/// re-appearing signal.
fn emitGroup(r: *Run, g: *Group, effective: Confidence) !void {
    if (alertQueued(r, g.identity)) return; // alert-once within the active episode

    const lead = g.members.items[0];
    const tier = bestTier(g);

    var srcs: std.ArrayList([]const u8) = .empty;
    for (g.members.items) |m| {
        if (!csvHas(srcs.items, m.source.id)) try srcs.append(r.a(), m.source.id);
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

    const occurrence_id = try occurrenceId(r.a(), g.identity, r.ctx.epoch_ms, false);
    try queueEvent(r, occurrence_id, .{
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
    }, if (effective == .high) try notifyMessage(r.a(), lead.title, g.identity, occurrence_id, lead.url, false) else null);
    r.ctx.changed = true;

    try r.alerts.append(r.a(), .{
        .event_identity = g.identity,
        .occurrence_id = occurrence_id,
        .epoch_ms = r.ctx.epoch_ms,
        .delivered = false,
        .tier = tier,
        .ev_kind = lead.event_kind,
        .title = lead.title,
        .url = lead.url,
    });
}

fn alertQueued(r: *Run, identity: []const u8) bool {
    for (r.alerts.items) |alert| {
        if (std.mem.eql(u8, alert.event_identity, identity)) return true;
    }
    return false;
}

/// Escalation pass: re-fire any tier-1 alert that has gone unacknowledged past
/// the configured window and has not already escalated. Driven by the persisted
/// alert records, so a decisive trip whose underlying signal does not re-appear
/// (a model that stays present, a statement that stays changed) still escalates.
fn escalateStale(r: *Run) !void {
    for (r.alerts.items) |*al| {
        if (al.tier != 1 or al.acknowledged or al.escalated) continue;
        // Only alerts that predate this run can escalate; one fired this poll
        // (epoch_ms == now) must not escalate in the same poll it tripped.
        if (al.epoch_ms >= r.ctx.epoch_ms) continue;
        const age_ms = r.ctx.epoch_ms - al.epoch_ms;
        if (age_ms < @as(i64, r.opts.escalate_after_s) * 1000) continue;

        const occurrence_id = try occurrenceId(r.a(), al.event_identity, al.epoch_ms, true);
        if (deliveryOccurrenceQueued(r.deliveries.items, occurrence_id)) continue;
        try queueEvent(r, occurrence_id, .{
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
        }, try notifyMessage(r.a(), al.title, al.event_identity, occurrence_id, al.url, true));
        r.ctx.changed = true;
        log("queued escalation for unacknowledged tier-1 alert '{s}' (age {d}s)", .{ al.event_identity, @divFloor(age_ms, 1000) });
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

/// Build the immutable event payload and enqueue one record for every required
/// sink. `saveState` commits these records before delivery begins.
fn queueEvent(r: *Run, occurrence_id: []const u8, f: EventFields, message: ?[]const u8) !void {
    const Emit = struct {
        schema: []const u8,
        event_id: []const u8,
        occurrence_id: []const u8,
        idempotency_key: []const u8,
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
        .occurrence_id = occurrence_id,
        .idempotency_key = occurrence_id,
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
    try appendDelivery(r, occurrence_id, f.event_id, "stdout", line, "");
    if (r.opts.event_sink_path != null) try appendDelivery(r, occurrence_id, f.event_id, "event_sink", line, "");
    if (r.opts.webhook_url != null) try appendDelivery(r, occurrence_id, f.event_id, "webhook", line, "");
    if (message) |text| try appendDelivery(r, occurrence_id, f.event_id, "notify", line, text);
}

fn appendDelivery(r: *Run, occurrence_id: []const u8, identity: []const u8, sink: []const u8, payload: []const u8, message: []const u8) !void {
    try r.deliveries.append(r.a(), .{
        .occurrence_id = occurrence_id,
        .event_identity = identity,
        .sink = sink,
        .payload = payload,
        .notify_message = message,
    });
}

fn occurrenceId(arena: Allocator, identity: []const u8, epoch_ms: i64, escalation: bool) ![]const u8 {
    const digest = std.hash.Wyhash.hash(0, identity);
    return std.fmt.allocPrint(arena, "occ-{x:0>16}-{d}-{s}", .{ digest, epoch_ms, if (escalation) "escalation" else "initial" });
}

fn deliveryOccurrenceQueued(deliveries: []const State.DeliveryRecord, occurrence_id: []const u8) bool {
    for (deliveries) |delivery| if (std.mem.eql(u8, delivery.occurrence_id, occurrence_id)) return true;
    return false;
}

fn appendLineIdempotent(ctx: *Context, path: []const u8, line: []const u8, occurrence_id: []const u8) !void {
    const existing = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    if (try eventSinkHasOccurrence(ctx.arena, existing, occurrence_id)) return;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.arena, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.append(ctx.arena, '\n');
    try out.appendSlice(ctx.arena, line);
    try out.append(ctx.arena, '\n');
    // Staged-and-renamed so a crash mid-write cannot tear the sink file.
    try events.writeFileAtomic(ctx.io, ctx.arena, path, out.items);
}

fn eventSinkHasOccurrence(arena: Allocator, data: []const u8, occurrence_id: []const u8) !bool {
    const Key = struct { occurrence_id: []const u8 = "" };
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const key = std.json.parseFromSliceLeaky(Key, arena, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        if (std.mem.eql(u8, key.occurrence_id, occurrence_id)) return true;
    }
    return false;
}

fn notifyMessage(arena: Allocator, title: []const u8, identity: []const u8, occurrence_id: []const u8, url: []const u8, escalate: bool) ![]const u8 {
    const tag = if (escalate) "ESCALATION" else "RESTORATION";
    return std.fmt.allocPrint(arena, "[{s}] {s} ({s}; idempotency={s}) {s}", .{ tag, title, identity, occurrence_id, url });
}

fn runNotify(ctx: *Context, message: []const u8) !void {
    const cmd = ctx.notify_cmd orelse return error.NotifyNotConfigured;
    const argv = [_][]const u8{ "sh", "-c", cmd, "fable-monitor", message };
    const result = try std.process.run(ctx.arena, ctx.io, .{ .argv = &argv });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.NotifyFailed,
        else => return error.NotifyFailed,
    }
}

const delivery_lease_ms: i64 = 5 * std.time.ms_per_min;
const max_retry_ms: i64 = std.time.ms_per_hour;
const max_delivery_claim = 32;

/// Claim due records under the state lock, perform side effects without it,
/// then checkpoint every result. A crash after sink success may replay once;
/// the stable occurrence ID makes that replay logically idempotent.
pub fn deliverPending(ctx: *Context, opts: Options, force: bool, identity_filter: ?[]const u8) !void {
    var claimed: std.ArrayList(State.DeliveryRecord) = .empty;
    {
        var transaction_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer transaction_arena.deinit();
        var transaction_ctx = deliveryTransactionContext(ctx, transaction_arena.allocator());
        var lock = try state_mod.acquireLock(&transaction_ctx);
        defer lock.release(transaction_ctx.io);
        const st = try state_mod.loadState(&transaction_ctx);
        for (st.deliveries) |*delivery| {
            if (claimed.items.len >= max_delivery_claim) break;
            if (delivery.delivered) continue;
            if (identity_filter) |wanted| {
                if (!std.mem.eql(u8, wanted, delivery.event_identity) and !std.mem.eql(u8, wanted, delivery.occurrence_id)) continue;
            }
            if (delivery.lease_until_ms > ctx.epoch_ms) continue;
            if (!force and delivery.next_retry_ms > ctx.epoch_ms) continue;
            delivery.lease_token = try randomLeaseToken(&transaction_ctx);
            delivery.lease_until_ms = ctx.epoch_ms + delivery_lease_ms;
            try claimed.append(ctx.arena, try cloneDelivery(ctx.arena, delivery.*));
        }
        if (claimed.items.len > 0) try state_mod.saveState(&transaction_ctx, st);
    }

    var failed = false;
    for (claimed.items) |delivery| {
        deliverOne(ctx, opts, delivery) catch |err| {
            failed = true;
            try finishDelivery(ctx, delivery, err);
            continue;
        };
        try finishDelivery(ctx, delivery, null);
    }

    const remaining = try pendingDeliveryCount(ctx, identity_filter);
    if (failed or remaining > 0) return error.DeliveryPending;
}

fn deliverOne(ctx: *Context, opts: Options, delivery: State.DeliveryRecord) !void {
    if (std.mem.eql(u8, delivery.sink, "stdout")) {
        var buf: [4096]u8 = undefined;
        var fw = Io.File.stdout().writer(ctx.io, &buf);
        try fw.interface.writeAll(delivery.payload);
        try fw.interface.writeAll("\n");
        try fw.interface.flush();
    } else if (std.mem.eql(u8, delivery.sink, "event_sink")) {
        const path = opts.event_sink_path orelse return error.EventSinkNotConfigured;
        try appendLineIdempotent(ctx, path, delivery.payload, delivery.occurrence_id);
    } else if (std.mem.eql(u8, delivery.sink, "webhook")) {
        const url = opts.webhook_url orelse return error.WebhookNotConfigured;
        try fetch.postJsonIdempotent(ctx, url, delivery.payload, delivery.occurrence_id);
    } else if (std.mem.eql(u8, delivery.sink, "notify")) {
        try runNotify(ctx, delivery.notify_message);
    } else {
        return error.UnknownDeliverySink;
    }
}

fn finishDelivery(ctx: *Context, claimed: State.DeliveryRecord, failure: ?anyerror) !void {
    var transaction_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer transaction_arena.deinit();
    var transaction_ctx = deliveryTransactionContext(ctx, transaction_arena.allocator());
    var lock = try state_mod.acquireLock(&transaction_ctx);
    defer lock.release(transaction_ctx.io);
    const st = try state_mod.loadState(&transaction_ctx);
    if (!applyDeliveryCompletion(st, claimed, failure, ctx.epoch_ms)) return;
    try settleDeliveredAlerts(transaction_ctx.arena, st);
    try state_mod.saveState(&transaction_ctx, st);
}

fn applyDeliveryCompletion(st: State, claimed: State.DeliveryRecord, failure: ?anyerror, now_ms: i64) bool {
    if (claimed.lease_token.len == 0) return false;
    for (st.deliveries) |*delivery| {
        if (!std.mem.eql(u8, delivery.occurrence_id, claimed.occurrence_id) or
            !std.mem.eql(u8, delivery.sink, claimed.sink) or
            !std.mem.eql(u8, delivery.lease_token, claimed.lease_token)) continue;
        delivery.lease_until_ms = 0;
        delivery.lease_token = "";
        delivery.attempts +|= 1;
        if (failure) |err| {
            delivery.last_error = @errorName(err);
            delivery.next_retry_ms = now_ms + retryDelayMs(delivery.occurrence_id, delivery.sink, delivery.attempts);
        } else {
            delivery.delivered = true;
            delivery.last_error = "";
            delivery.next_retry_ms = 0;
        }
        return true;
    }
    return false;
}

fn deliveryTransactionContext(ctx: *const Context, arena: Allocator) Context {
    return .{
        .io = ctx.io,
        .arena = arena,
        .state_path = ctx.state_path,
        .log_path = ctx.log_path,
        .notify_cmd = ctx.notify_cmd,
        .observed_at = ctx.observed_at,
        .epoch_ms = ctx.epoch_ms,
        .run_id = ctx.run_id,
    };
}

fn randomLeaseToken(ctx: *Context) ![]const u8 {
    var random: [16]u8 = undefined;
    Io.random(ctx.io, &random);
    return std.fmt.allocPrint(ctx.arena, "{x:0>16}{x:0>16}", .{
        std.mem.readInt(u64, random[0..8], .little),
        std.mem.readInt(u64, random[8..16], .little),
    });
}

fn cloneDelivery(arena: Allocator, delivery: State.DeliveryRecord) !State.DeliveryRecord {
    var cloned = delivery;
    cloned.occurrence_id = try arena.dupe(u8, delivery.occurrence_id);
    cloned.event_identity = try arena.dupe(u8, delivery.event_identity);
    cloned.sink = try arena.dupe(u8, delivery.sink);
    cloned.payload = try arena.dupe(u8, delivery.payload);
    cloned.notify_message = try arena.dupe(u8, delivery.notify_message);
    cloned.lease_token = try arena.dupe(u8, delivery.lease_token);
    cloned.last_error = try arena.dupe(u8, delivery.last_error);
    return cloned;
}

fn settleDeliveredAlerts(arena: Allocator, st: State) !void {
    for (st.alerts) |*alert| {
        if (!alert.delivered and occurrenceDelivered(st.deliveries, alert.occurrence_id)) alert.delivered = true;
        const escalation_id = try occurrenceId(arena, alert.event_identity, alert.epoch_ms, true);
        if (!alert.escalated and deliveryOccurrenceQueued(st.deliveries, escalation_id) and occurrenceDelivered(st.deliveries, escalation_id))
            alert.escalated = true;
    }
}

fn occurrenceDelivered(deliveries: []const State.DeliveryRecord, occurrence_id: []const u8) bool {
    var found = false;
    for (deliveries) |delivery| {
        if (!std.mem.eql(u8, delivery.occurrence_id, occurrence_id)) continue;
        found = true;
        if (!delivery.delivered) return false;
    }
    return found;
}

fn retryDelayMs(occurrence_id: []const u8, sink: []const u8, attempts: u32) i64 {
    const shift: u5 = @intCast(@min(attempts -| 1, 10));
    const base = @min(@as(i64, 5 * std.time.ms_per_s) << shift, max_retry_ms);
    const jitter_seed = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, occurrence_id), sink);
    const jitter = @as(i64, @intCast(jitter_seed % @as(u64, @intCast(@max(1, @divTrunc(base, 5))))));
    return @min(base + jitter, max_retry_ms);
}

fn pendingDeliveryCount(ctx: *Context, identity_filter: ?[]const u8) !usize {
    var transaction_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer transaction_arena.deinit();
    var transaction_ctx = deliveryTransactionContext(ctx, transaction_arena.allocator());
    var lock = try state_mod.acquireLock(&transaction_ctx);
    defer lock.release(transaction_ctx.io);
    const st = try state_mod.loadState(&transaction_ctx);
    var count: usize = 0;
    for (st.deliveries) |delivery| {
        if (delivery.delivered) continue;
        if (identity_filter) |wanted| {
            if (!std.mem.eql(u8, wanted, delivery.event_identity) and !std.mem.eql(u8, wanted, delivery.occurrence_id)) continue;
        }
        count += 1;
    }
    return count;
}

pub fn inspectDeliveries(ctx: *Context) !void {
    const st = try state_mod.loadState(ctx);
    const counts = st.deliveryCounts();
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(ctx.io, &buf);
    const out = &fw.interface;
    try out.print("{s:<38} {s:<12} {s:<9} {s:<8} {s}\n", .{ "occurrence", "sink", "status", "attempts", "last_error" });
    for (st.deliveries) |delivery| try out.print("{s:<38} {s:<12} {s:<9} {d:<8} {s}\n", .{
        delivery.occurrence_id,
        delivery.sink,
        if (delivery.delivered) "delivered" else "pending",
        delivery.attempts,
        delivery.last_error,
    });
    try out.print("pending: {d}; failed: {d}\n", .{ counts.pending, counts.failed });
    try out.flush();
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
    const cfg = config.load(ctx, .{
        .sources_path = opts.sources_path,
        .only_csv = opts.only_csv,
        .disable_csv = opts.disable_csv,
        .required_source_ids = opts.required_source_ids,
        .minimum_decisive_sources = opts.minimum_decisive_sources,
    });
    const st = state_mod.loadState(ctx) catch |err| switch (err) {
        error.FileNotFound => State{},
        else => return err,
    };
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
    const delivery_counts = st.deliveryCounts();
    try out.print("delivery backlog: {d} pending, {d} failed\n", .{ delivery_counts.pending, delivery_counts.failed });
    try out.flush();
}

/// Render a real elapsed duration ("42s", "5m3s", "2h10m", "3d4h") into the
/// run arena, which outlives the audit table's printing.
fn agoText(arena: Allocator, now_ms: i64, then_ms: i64) []const u8 {
    if (then_ms == 0) return "never";
    const secs: u64 = @intCast(@max(0, @divFloor(now_ms - then_ms, 1000)));
    // Audit rendering is read-only UI; a placeholder is preferable to failing
    // the command when its display-only duration allocation is unavailable.
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

    const st = state_mod.loadState(ctx) catch |err| switch (err) {
        error.FileNotFound => {
            log("no state to acknowledge against", .{});
            return;
        },
        else => return err,
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

pub const PreflightStatus = enum { pass, warn, fail, skipped };

/// Stable categories for supervisors; check names and human detail may grow.
pub const PreflightCategory = enum {
    config,
    dependency,
    state_permissions,
    log_permissions,
    outbox_permissions,
    sink_configuration,
    sink_permissions,
    disk_space,
    source_egress,
    source_schema,
    decisive_coverage,
    secret,
};

pub const PreflightCheck = struct {
    name: []const u8,
    category: PreflightCategory,
    status: PreflightStatus,
    source_id: []const u8 = "",
    detail: []const u8 = "",
};

pub const PreflightResult = struct {
    schema: []const u8 = "fable-monitor.preflight/1",
    ok: bool,
    checks: []const PreflightCheck,
};

/// Machine-readable preflight API. Expected operational failures are returned
/// as stable checks; only resource failures prevent producing a result.
pub fn preflightResult(ctx: *Context, opts: Options) !PreflightResult {
    var checks: std.ArrayList(PreflightCheck) = .empty;
    const cfg = config.loadChecked(ctx, .{
        .sources_path = opts.sources_path,
        .only_csv = opts.only_csv,
        .disable_csv = opts.disable_csv,
        .required_source_ids = opts.required_source_ids,
        .minimum_decisive_sources = opts.minimum_decisive_sources,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        try addPreflightCheck(ctx.arena, &checks, "sources_config", .config, .fail, "", @errorName(err));
        return .{ .ok = false, .checks = checks.items };
    };
    try addPreflightCheck(ctx.arena, &checks, "sources_config", .config, .pass, "", cfg.origin);

    inline for (.{ "curl", "zstd" }) |bin| {
        try addPreflightCheck(ctx.arena, &checks, bin, .dependency, if (fetch.toolAvailable(ctx, bin)) .pass else .fail, "", "required executable");
    }

    try checkWritablePath(ctx, &checks, "state", ctx.state_path, .state_permissions);
    try checkWritablePath(ctx, &checks, "outbox", try std.fmt.allocPrint(ctx.arena, "{s}.lock", .{ctx.state_path}), .outbox_permissions);
    try checkWritablePath(ctx, &checks, "log", ctx.log_path, .log_permissions);
    const segment_probe = try std.fmt.allocPrint(ctx.arena, "{s}.segments/probe", .{ctx.log_path});
    const segments_ready = if (Io.Dir.cwd().createDirPathStatus(ctx.io, std.fs.path.dirname(segment_probe).?, .fromMode(0o700))) |_|
        true
    else |err| blk: {
        try addPreflightCheck(ctx.arena, &checks, "log_segments", .log_permissions, .fail, "", @errorName(err));
        break :blk false;
    };
    if (segments_ready) {
        try checkWritablePath(ctx, &checks, "log_segments", segment_probe, .log_permissions);
    }

    try checkDisk(ctx, &checks, "state_disk", ctx.state_path);
    // The durable delivery outbox is stored in the state generation. Keep a
    // distinct machine check so operators can gate that requirement directly.
    try checkDisk(ctx, &checks, "outbox_disk", ctx.state_path);
    try checkDisk(ctx, &checks, "log_disk", ctx.log_path);
    if (opts.event_sink_path) |path| {
        try checkWritablePath(ctx, &checks, "event_sink", path, .sink_permissions);
        try checkDisk(ctx, &checks, "event_sink_disk", path);
    } else {
        try addPreflightCheck(ctx.arena, &checks, "event_sink", .sink_configuration, .warn, "", "stdout only");
    }
    try checkOptionalHttpsSink(ctx.arena, &checks, "webhook", opts.webhook_url);
    try checkOptionalHttpsSink(ctx.arena, &checks, "heartbeat", opts.heartbeat_url);
    try addPreflightCheck(ctx.arena, &checks, "notify", .sink_configuration, if (ctx.notify_cmd == null) .warn else .pass, "", if (ctx.notify_cmd == null) "not configured" else "configured");

    const has_api_key = if (opts.anthropic_api_key) |key| key.len > 0 else false;
    try addPreflightCheck(ctx.arena, &checks, "anthropic_api_key", .secret, if (has_api_key) .pass else .warn, "", if (has_api_key) "configured" else "api_probe sources skipped");
    var decisive_ok: u32 = 0;
    var required_failed = false;
    for (cfg.sources) |src| {
        if (!src.enabled) continue;
        if (src.kind == .api_probe and !has_api_key) {
            try addPreflightCheck(ctx.arena, &checks, "source_egress", .source_egress, .skipped, src.id, "ANTHROPIC_API_KEY unset");
            if (requiredId(opts.required_source_ids, src.id)) required_failed = true;
            continue;
        }
        if (opts.fixtures_dir) |dir| {
            const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ dir, src.id });
            const body = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(16 * 1024 * 1024)) catch |err| {
                if (err == error.OutOfMemory) return err;
                try addPreflightCheck(ctx.arena, &checks, "source_egress", .source_egress, .fail, src.id, @errorName(err));
                if (requiredId(opts.required_source_ids, src.id)) required_failed = true;
                continue;
            };
            const content_type = switch (src.kind) {
                .federal_register, .federal_register_public_inspection, .api_probe, .market_watch => "application/json",
                .feed_watch => "application/xml",
                .model_list_probe, .statement_watch, .keyword_watch => "text/html",
            };
            try addPreflightCheck(ctx.arena, &checks, "source_egress", .source_egress, .pass, src.id, "fixture");
            if (!try preflightSchemaValid(ctx.arena, src, body, content_type)) {
                try addPreflightCheck(ctx.arena, &checks, "source_schema", .source_schema, .fail, src.id, "unexpected fixture shape");
                if (requiredId(opts.required_source_ids, src.id)) required_failed = true;
                continue;
            }
            try addPreflightCheck(ctx.arena, &checks, "source_schema", .source_schema, .pass, src.id, "valid fixture");
            if (src.isDecisive()) decisive_ok += 1;
            continue;
        }
        const api_key: ?[]const u8 = if (src.kind == .api_probe) opts.anthropic_api_key else null;
        const resp = fetch.fetchConditional(ctx, src.url, "", "", api_key) catch |err| {
            if (err == error.OutOfMemory) return err;
            try addPreflightCheck(ctx.arena, &checks, "source_egress", .source_egress, .fail, src.id, @errorName(err));
            if (requiredId(opts.required_source_ids, src.id)) required_failed = true;
            continue;
        };
        try addPreflightCheck(ctx.arena, &checks, "source_egress", .source_egress, .pass, src.id, try std.fmt.allocPrint(ctx.arena, "HTTP {d}", .{resp.status}));
        if (!try preflightSchemaValid(ctx.arena, src, resp.body, resp.content_type)) {
            try addPreflightCheck(ctx.arena, &checks, "source_schema", .source_schema, .fail, src.id, "unexpected response shape");
            if (requiredId(opts.required_source_ids, src.id)) required_failed = true;
            continue;
        }
        try addPreflightCheck(ctx.arena, &checks, "source_schema", .source_schema, .pass, src.id, "valid");
        if (src.isDecisive()) decisive_ok += 1;
    }

    const coverage_ok = preflightCoverageHealthy(decisive_ok, required_failed, opts.minimum_decisive_sources);
    try addPreflightCheck(ctx.arena, &checks, "decisive_coverage", .decisive_coverage, if (coverage_ok) .pass else .fail, "", try std.fmt.allocPrint(ctx.arena, "{d}/{d} decisive sources", .{ decisive_ok, opts.minimum_decisive_sources }));
    return .{ .ok = preflightChecksOk(checks.items), .checks = checks.items };
}

/// JSON support for a future `preflight --json` CLI without coupling main to
/// the result schema now.
pub fn preflightJson(arena: Allocator, result: PreflightResult) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, result, .{});
}

/// Human CLI compatibility wrapper.
pub fn preflight(ctx: *Context, opts: Options) !void {
    const result = try preflightResult(ctx, opts);
    for (result.checks) |check| log("preflight: {s} category={s} status={s} source={s} detail={s}", .{
        check.name,
        @tagName(check.category),
        @tagName(check.status),
        check.source_id,
        check.detail,
    });
    if (!result.ok) return error.PreflightFailed;
    log("preflight: ok", .{});
}

fn addPreflightCheck(arena: Allocator, checks: *std.ArrayList(PreflightCheck), name: []const u8, category: PreflightCategory, status: PreflightStatus, source_id: []const u8, detail: []const u8) !void {
    try checks.append(arena, .{ .name = name, .category = category, .status = status, .source_id = source_id, .detail = detail });
}

fn preflightChecksOk(checks: []const PreflightCheck) bool {
    for (checks) |check| if (check.status == .fail) return false;
    return true;
}

fn checkWritablePath(ctx: *Context, checks: *std.ArrayList(PreflightCheck), name: []const u8, path: []const u8, category: PreflightCategory) !void {
    var existing = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            try addPreflightCheck(ctx.arena, checks, name, category, .fail, "", @errorName(err));
            return;
        },
    };
    if (existing) |*file| file.close(ctx.io);
    const probe = try std.fmt.allocPrint(ctx.arena, "{s}.preflight-{d}", .{ path, ctx.epoch_ms });
    var file = Io.Dir.cwd().createFile(ctx.io, probe, .{ .permissions = .fromMode(0o600) }) catch |err| {
        try addPreflightCheck(ctx.arena, checks, name, category, .fail, "", @errorName(err));
        return;
    };
    var file_open = true;
    defer if (file_open) file.close(ctx.io);
    errdefer Io.Dir.cwd().deleteFile(ctx.io, probe) catch {};
    file.writeStreamingAll(ctx.io, "preflight\n") catch |err| {
        try addPreflightCheck(ctx.arena, checks, name, category, .fail, "", @errorName(err));
        return;
    };
    file.sync(ctx.io) catch |err| {
        try addPreflightCheck(ctx.arena, checks, name, category, .fail, "", @errorName(err));
        return;
    };
    file.close(ctx.io);
    file_open = false;
    Io.Dir.cwd().deleteFile(ctx.io, probe) catch |err| {
        try addPreflightCheck(ctx.arena, checks, name, category, .fail, "", @errorName(err));
        return;
    };
    try addPreflightCheck(ctx.arena, checks, name, category, .pass, "", path);
}

fn checkDisk(ctx: *Context, checks: *std.ArrayList(PreflightCheck), name: []const u8, path: []const u8) !void {
    const minimum_free: u64 = 10 * 1024 * 1024;
    const free = (try diskFreeBytes(ctx.arena, path)) orelse {
        try addPreflightCheck(ctx.arena, checks, name, .disk_space, .fail, "", "statvfs failed");
        return;
    };
    try addPreflightCheck(ctx.arena, checks, name, .disk_space, if (free >= minimum_free) .pass else .fail, "", try std.fmt.allocPrint(ctx.arena, "{d} bytes free", .{free}));
}

fn checkOptionalHttpsSink(arena: Allocator, checks: *std.ArrayList(PreflightCheck), name: []const u8, value: ?[]const u8) !void {
    const url = value orelse {
        try addPreflightCheck(arena, checks, name, .sink_configuration, .warn, "", "not configured");
        return;
    };
    const uri = std.Uri.parse(url) catch {
        try addPreflightCheck(arena, checks, name, .sink_configuration, .fail, "", "invalid URL");
        return;
    };
    const valid = std.ascii.eqlIgnoreCase(uri.scheme, "https") and uri.host != null and uri.user == null and uri.password == null and (uri.port == null or uri.port.? == 443);
    try addPreflightCheck(arena, checks, name, .sink_configuration, if (valid) .pass else .fail, "", if (valid) "HTTPS URL" else "HTTPS URL required");
}

fn preflightCoverageHealthy(decisive_ok: u32, required_failed: bool, minimum: u32) bool {
    return !required_failed and decisive_ok >= minimum;
}

fn preflightSchemaValid(arena: Allocator, src: Source, body: []const u8, content_type: []const u8) !bool {
    if (body.len == 0) return false;
    return switch (src.kind) {
        .api_probe => blk: {
            if (!isJsonContentType(content_type)) break :blk false;
            _ = std.json.parseFromSliceLeaky(ApiModelsResponse, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break :blk false,
            };
            break :blk true;
        },
        .federal_register, .federal_register_public_inspection => blk: {
            if (!isJsonContentType(content_type)) break :blk false;
            const PreflightFrResponse = FrResponse;
            const decoded = std.json.parseFromSliceLeaky(PreflightFrResponse, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break :blk false,
            };
            if (decoded.results != null) break :blk true;
            if (src.kind == .federal_register_public_inspection) {
                if (decoded.meta) |meta| break :blk meta.pil_unavailability_message.len > 0;
            }
            break :blk false;
        },
        .feed_watch => blk: {
            const entries = try feed.parse(arena, body);
            break :blk entries.len > 0;
        },
        .market_watch => isJsonContentType(content_type) and extractMarketPrice(body) != null,
        .model_list_probe, .statement_watch, .keyword_watch => blk: {
            if (!isHtmlContentType(content_type)) break :blk false;
            const normalized = try html.normalizeHtml(arena, body);
            break :blk normalized.len > 0;
        },
    };
}

fn isHtmlContentType(value: []const u8) bool {
    const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..semicolon], " \t"), "text/html");
}

fn diskFreeBytes(arena: Allocator, path: []const u8) !?u64 {
    const c = @cImport(@cInclude("sys/statvfs.h"));
    const dir = std.fs.path.dirname(path) orelse ".";
    const dir_z = try arena.dupeZ(u8, dir);
    var stat: c.struct_statvfs = undefined;
    if (c.statvfs(dir_z.ptr, &stat) != 0) return null;
    return try std.math.mul(u64, @intCast(stat.f_bavail), @intCast(stat.f_frsize));
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
        .io = testing.io,
        .arena = arena,
        .state_path = "",
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "2026-07-04T00:00:00Z",
        .epoch_ms = epoch_ms,
    };
}

test "repeated polls do not grow memory per tick (soak)" {
    // Guard the loop-mode memory-growth class of bug: many full poll runs, each
    // on a per-tick arena reset between ticks, must not accumulate allocations
    // on the backing allocator. A DebugAllocator backs the tick arena and its
    // deinit reports any allocation that outlived every arena reset — a leak.
    // Its Check being .ok is the assertion.
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    // File-based tests here run from the repo root; drive the real baseline
    // fixtures and use the established .test-fable-monitor-* path convention for
    // this run's state and log so nothing leaks into the tracked tree.
    const fixtures_dir = "tests/fixtures/baseline";
    const state_path = ".test-fable-monitor-soak-state.zst";
    const log_path = ".test-fable-monitor-soak-log.zst";
    defer cwd.deleteFile(io, state_path) catch {};
    defer cwd.deleteFile(io, state_path ++ ".backup") catch {};
    defer cwd.deleteFile(io, state_path ++ ".lock") catch {};
    defer cwd.deleteFile(io, log_path) catch {};
    defer cwd.deleteFile(io, log_path ++ ".lock") catch {};
    defer cwd.deleteFile(io, log_path ++ ".manifest") catch {};
    defer cwd.deleteFile(io, log_path ++ ".manifest.backup") catch {};
    defer cwd.deleteTree(io, log_path ++ ".segments") catch {};

    var gpa: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer testing.expectEqual(std.heap.Check.ok, gpa.deinit()) catch @panic("soak: leak across poll ticks");

    var tick_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer tick_arena.deinit();

    const opts = Options{
        .fixtures_dir = fixtures_dir,
        .force_all = true,
        .only_csv = "anthropic_model_list,anthropic_pricing,anthropic_statement,fr_pi_bis",
    };

    var retained_after_first: usize = 0;
    var i: i64 = 0;
    while (i < 40) : (i += 1) {
        const a = tick_arena.allocator();
        var ctx = Context{
            .io = io,
            .arena = a,
            .state_path = state_path,
            .log_path = log_path,
            .notify_cmd = null,
            .observed_at = "2026-07-04T00:00:00Z",
            .epoch_ms = 1_000 + i * 60_000,
        };
        // Baseline fixtures never trip, so every tick should be healthy; treat a
        // degraded/failed outcome as a real regression rather than swallowing it.
        try run(&ctx, opts);
        // Mirror loop mode: reclaim the tick's arena before the next iteration.
        _ = tick_arena.reset(.retain_capacity);
        // After warmup, the backing allocator's live bytes must not keep growing.
        const live = gpa.total_requested_bytes;
        if (i == 4) retained_after_first = live;
        if (i > 4) try testing.expect(live <= retained_after_first);
    }
}

test "state-critical accumulator allocation failures propagate" {
    const src = Source{ .id = "source", .kind = .statement_watch, .tier = .tier1, .url = "", .label = "" };

    {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        var ctx = testContext(failing.allocator(), 1_000);
        var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };
        try testing.expectError(error.OutOfMemory, r.markPolled(src.id));
    }
    {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        var ctx = testContext(failing.allocator(), 1_000);
        var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };
        try testing.expectError(error.OutOfMemory, recordStatus(&r, src, true));
    }
    {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        var ctx = testContext(failing.allocator(), 1_000);
        const prev = State{ .validators = @constCast(&[_]State.Validator{.{ .id = src.id, .etag = "etag" }}) };
        var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = prev };
        try testing.expectError(error.OutOfMemory, carryForward(&r, src));
    }
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
    try recordStatus(&r1, src, true);
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
    try handlePollFailure(&r2, src);
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
    try recordStatus(&r3, src, true);
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
    try recordStatus(&r1, src, true);
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
    try recordStatus(&r2, src, true);
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
    try recordStatus(&r3, src, true);
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
    try recordStatus(&r1, src, true);
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
    try recordStatus(&r2, src, true);
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
    try recordStatus(&r, src, true);
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
    try recordStatus(&r1, src, true);
    try detectModelList(&r1, src, absent);
    const st1 = State{
        .version = state_mod.current_version,
        .model_present = r1.models.items,
        .source_status = r1.statuses.items,
    };

    // A mere mention inside suspension copy neither trips nor records
    // presence (recording it would swallow the later real transition).
    var r2 = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = st1 };
    try recordStatus(&r2, src, true);
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
    try recordStatus(&r3, src, true);
    try detectModelList(&r3, src, listed);
    try testing.expectEqual(@as(usize, 1), r3.signals.items.len);
    try testing.expectEqual(Confidence.high, r3.signals.items[0].confidence);
    try testing.expectEqualStrings("model_present:claude-fable-5", r3.signals.items[0].identity);
}

test "model HTML ignores hidden and example-only identifiers and records evidence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 2_000);
    const src = Source{ .id = "list", .kind = .model_list_probe, .tier = .tier1, .url = "https://docs.example.com/models", .label = "Models", .match = &.{"claude-fable-5"} };
    const prev = State{ .source_status = @constCast(&[_]State.SourceStatus{
        .{ .id = "list", .last_poll_ms = 1_000, .last_success_ms = 1_000 },
    }) };

    var decoys = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{}, .prev = prev };
    try detectModelList(&decoys, src,
        \\<!-- claude-fable-5 -->
        \\<script>const model = "claude-fable-5"</script>
        \\<pre><code>{"model":"claude-fable-5"}</code></pre>
    );
    try testing.expectEqual(@as(usize, 0), decoys.models.items.len);
    try testing.expectEqual(@as(usize, 0), decoys.signals.items.len);

    var visible = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{}, .prev = prev };
    try detectModelList(&visible, src, "<ul><li>claude-fable-5</li></ul>");
    try testing.expectEqual(@as(usize, 1), visible.signals.items.len);
    try testing.expect(std.mem.indexOf(u8, visible.signals.items[0].detail, "detector=2") != null);
    try testing.expect(std.mem.indexOf(u8, visible.signals.items[0].detail, "hash=") != null);
    try testing.expect(std.mem.indexOf(u8, visible.signals.items[0].detail, "excerpt=claude-fable-5") != null);
    try resolveTrips(&visible);
    try testing.expect(std.mem.indexOf(u8, ctx.events.items[0].detail, "detector=2") != null);
    try testing.expect(std.mem.indexOf(u8, visible.deliveries.items[0].payload, "detector=2") != null);
}

test "Federal Register publication is reevaluated after preliminary inspection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 2_000);
    const pi = Source{ .id = "pi", .kind = .federal_register_public_inspection, .tier = .tier2, .url = "https://federalregister.gov/pi", .label = "PI" };
    const published = Source{ .id = "published", .kind = .federal_register, .tier = .tier2, .url = "https://federalregister.gov/docs", .label = "Published" };
    const body =
        \\{"results":[{"document_number":"2026-12345","title":"Anthropic export authorization","abstract":"Claude Fable 5 access","publication_date":"2026-07-14"}]}
    ;

    var preliminary = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{}, .prev = .{} };
    try detectFederalRegister(&preliminary, pi, body);
    try testing.expectEqualStrings("fr:preliminary:2026-12345", preliminary.seen.items[0]);
    const after_pi = State{ .federal_register_seen = preliminary.seen.items };

    var final = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{}, .prev = after_pi };
    try detectFederalRegister(&final, published, body);
    try testing.expectEqual(@as(usize, 1), final.signals.items.len);
    try testing.expectEqualStrings("fr_doc:published:2026-12345", final.signals.items[0].identity);
    try testing.expect(std.mem.indexOf(u8, final.signals.items[0].detail, "detector=2") != null);

    // A legacy unqualified key is similarly treated as preliminary for the
    // authoritative publication pass, but still suppresses another PI alert.
    const legacy = State{ .federal_register_seen = @constCast(&[_][]const u8{"2026-12345"}) };
    try testing.expect(!federalRegisterSeen(legacy, .federal_register, "fr:published:2026-12345", "2026-12345"));
    try testing.expect(federalRegisterSeen(legacy, .federal_register_public_inspection, "fr:preliminary:2026-12345", "2026-12345"));
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
    try recordStatus(&r, src, true);
    try markChanged(&r, src);
    try recordStatus(&r, src, false);
    try testing.expectEqual(@as(usize, 1), r.statuses.items.len);
    const st = r.statuses.items[0];
    try testing.expectEqual(@as(i64, 5_000), st.last_poll_ms);
    try testing.expectEqual(@as(i64, 0), st.last_success_ms); // detector failure wins
    try testing.expectEqual(@as(i64, 5_000), st.last_change_ms); // markChanged survives
}

test "change detected before status creation preserves last_change ordering" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = testContext(arena_state.allocator(), 7_000);
    const src = Source{ .id = "source", .kind = .keyword_watch, .tier = .tier2, .url = "", .label = "" };
    var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = undefined, .prev = .{} };

    try markChanged(&r, src);
    try recordStatus(&r, src, true);
    try testing.expectEqual(@as(i64, 7_000), r.statuses.items[0].last_poll_ms);
    try testing.expectEqual(@as(i64, 7_000), r.statuses.items[0].last_change_ms);
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

    const capped = try capFeeds(&r, max_feed_seen_per_source);
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

test "correlated mirrors do not promote advisory confidence" {
    const a = Source{ .id = "fr-term", .kind = .federal_register, .tier = .tier2, .url = "https://www.federalregister.gov/api/v1/documents?term=anthropic", .label = "term" };
    const mirror = Source{ .id = "fr-agency", .kind = .federal_register, .tier = .tier2, .url = "https://federalregister.gov/api/v1/documents?agency=bis", .label = "agency" };
    const preliminary = Source{ .id = "fr-pi", .kind = .federal_register_public_inspection, .tier = .tier2, .url = "https://www.federalregister.gov/api/v1/public-inspection", .label = "pi" };
    const explicit = Source{ .id = "fr-independent", .kind = .federal_register, .tier = .tier2, .url = "https://www.federalregister.gov/other", .label = "other", .lead_time = "independent corroborator" };
    const bis = Source{ .id = "bis", .kind = .keyword_watch, .tier = .tier2, .url = "https://www.bis.gov/news", .label = "BIS" };

    try testing.expect(!sourcesAreIndependent(a, mirror));
    try testing.expect(!sourcesAreIndependent(a, preliminary));
    try testing.expect(sourcesAreIndependent(a, explicit));
    try testing.expect(sourcesAreIndependent(a, bis));
    try testing.expect(sameOperator("https://api.service.co.uk/a", "https://www.service.co.uk/b"));
    try testing.expect(!sameOperator("https://api.first.co.uk/a", "https://www.second.co.uk/b"));

    var group = Group{ .identity = "same", .confidence = .advisory };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    try testing.expect(groupAddsIndependentSource(&group, a));
    try group.members.append(alloc, .{ .source = a, .confidence = .advisory, .event_kind = "x", .identity = "same" });
    try testing.expect(!groupAddsIndependentSource(&group, mirror));
    try testing.expect(groupAddsIndependentSource(&group, bis));
}

test "API model parsing matches only exact typed model IDs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 2_000);
    const src = Source{
        .id = "api",
        .kind = .api_probe,
        .tier = .tier1,
        .url = "https://example.com/v1/models",
        .label = "API",
        .match = &.{"claude-fable-5"},
        .poll = .fast,
    };
    const prev = State{ .source_status = @constCast(&[_]State.SourceStatus{
        .{ .id = "api", .last_poll_ms = 1_000, .last_success_ms = 1_000 },
    }) };

    var decoy = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{}, .prev = prev };
    try detectModelList(&decoy, src,
        \\{"data":[{"id":"claude-fable-5-preview","type":"model"},{"id":"other","type":"model","description":"claude-fable-5"}]}
    );
    try testing.expectEqual(@as(usize, 0), decoy.models.items.len);
    try testing.expectEqual(@as(usize, 0), decoy.signals.items.len);

    var exact = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{}, .prev = prev };
    try detectModelList(&exact, src, "{\"data\":[{\"id\":\"claude-fable-5\",\"type\":\"model\"}]}");
    try testing.expectEqual(@as(usize, 1), exact.models.items.len);
    try testing.expectEqual(@as(usize, 1), exact.signals.items.len);

    var drift = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{}, .prev = prev };
    try testing.expectError(error.FetchFailed, detectModelList(&drift, src, "{\"models\":[]}"));
}

test "failed first observation cannot establish a model baseline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 2_000);
    const src = Source{ .id = "api", .kind = .api_probe, .tier = .tier1, .url = "", .label = "", .match = &.{"claude-fable-5"} };
    const failed_prev = State{ .source_status = @constCast(&[_]State.SourceStatus{
        .{ .id = "api", .last_poll_ms = 1_000, .last_success_ms = 0 },
    }) };
    var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{}, .prev = failed_prev };
    try detectModelList(&r, src, "{\"data\":[{\"id\":\"claude-fable-5\",\"type\":\"model\"}]}");
    try testing.expectEqual(@as(usize, 1), r.models.items.len);
    try testing.expectEqual(@as(usize, 0), r.signals.items.len);
}

test "coverage classification distinguishes healthy degraded and failed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = testContext(arena_state.allocator(), 0);

    ctx.epoch_ms = 30_000;
    const decisive = Source{ .id = "decisive", .kind = .statement_watch, .tier = .tier1, .url = "", .label = "", .poll = .fast };
    const cfg = Config{ .fast_interval_s = 10, .sources = @constCast(&[_]Source{decisive}) };
    const fresh = State{ .source_status = @constCast(&[_]State.SourceStatus{.{ .id = "decisive", .last_success_ms = 29_000 }}) };
    var healthy = Run{ .ctx = &ctx, .opts = .{}, .cfg = cfg, .prev = .{}, .n_due = 2, .n_ok = 2, .n_decisive_ok = 1 };
    try testing.expectEqual(Outcome.healthy, classifyOutcome(&healthy, fresh));
    healthy.n_fail = 1;
    try testing.expectEqual(Outcome.degraded, classifyOutcome(&healthy, fresh));
    const stale = State{ .source_status = @constCast(&[_]State.SourceStatus{.{ .id = "decisive", .last_success_ms = 1 }}) };
    try testing.expectEqual(Outcome.failed, classifyOutcome(&healthy, stale));

    var required = Run{ .ctx = &ctx, .opts = .{ .required_source_ids = &.{"decisive"} }, .cfg = cfg, .prev = .{} };
    try testing.expectEqual(Outcome.failed, classifyOutcome(&required, stale));
    try testing.expectEqual(Outcome.healthy, classifyOutcome(&required, fresh));
}

test "quiet tick remains healthy while prior decisive success is fresh" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = testContext(arena_state.allocator(), 50_000);
    const src = Source{ .id = "required", .kind = .model_list_probe, .tier = .tier1, .url = "", .label = "", .poll = .fast };
    const cfg = Config{ .fast_interval_s = 30, .sources = @constCast(&[_]Source{src}) };
    const st = State{ .source_status = @constCast(&[_]State.SourceStatus{.{ .id = "required", .last_success_ms = 40_000 }}) };
    var r = Run{ .ctx = &ctx, .opts = .{ .required_source_ids = &.{"required"} }, .cfg = cfg, .prev = st, .n_due = 0 };
    try testing.expectEqual(Outcome.healthy, classifyOutcome(&r, st));
}

test "preflight decisive coverage fails all and required failures" {
    try testing.expect(!preflightCoverageHealthy(0, false, 1));
    try testing.expect(!preflightCoverageHealthy(2, true, 1));
    try testing.expect(!preflightCoverageHealthy(1, false, 2));
    try testing.expect(preflightCoverageHealthy(2, false, 2));
}

test "preflight validates decisive response schemas" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const api = Source{ .id = "api", .kind = .api_probe, .tier = .tier1, .url = "", .label = "" };
    try testing.expect(try preflightSchemaValid(arena, api, "{\"data\":[]}", "application/json; charset=utf-8"));
    try testing.expect(!try preflightSchemaValid(arena, api, "{\"models\":[]}", "application/json"));
    try testing.expect(!try preflightSchemaValid(arena, api, "{\"data\":[]}", "text/html"));

    const statement = Source{ .id = "statement", .kind = .statement_watch, .tier = .tier1, .url = "", .label = "" };
    try testing.expect(try preflightSchemaValid(arena, statement, "<p>status</p>", "text/html"));
    try testing.expect(!try preflightSchemaValid(arena, statement, "", "text/html"));
    try testing.expect(!try preflightSchemaValid(arena, statement, "<p>status</p>", "application/json"));

    const fr = Source{ .id = "fr", .kind = .federal_register, .tier = .tier2, .url = "", .label = "" };
    try testing.expect(try preflightSchemaValid(arena, fr, "{\"results\":[]}", "application/json"));
    try testing.expect(!try preflightSchemaValid(arena, fr, "{}", "application/json"));
    try testing.expect(!try preflightSchemaValid(arena, fr, "{\"results\":[]}", "text/html"));

    const public_inspection = Source{ .id = "fr_pi", .kind = .federal_register_public_inspection, .tier = .tier2, .url = "", .label = "" };
    const unavailable = "{\"count\":0,\"meta\":{\"pil_unavailability_message\":\"returns at 8:45AM Eastern\"}}";
    try testing.expect(try preflightSchemaValid(arena, public_inspection, unavailable, "application/json"));
    try testing.expect(!try preflightSchemaValid(arena, fr, unavailable, "application/json"));
}

test "preflight JSON result has stable schema categories and status" {
    const checks = [_]PreflightCheck{
        .{ .name = "state", .category = .state_permissions, .status = .pass, .detail = "/tmp/state" },
        .{ .name = "source_schema", .category = .source_schema, .status = .fail, .source_id = "api", .detail = "unexpected response shape" },
    };
    const result = PreflightResult{ .ok = false, .checks = &checks };
    const encoded = try preflightJson(testing.allocator, result);
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"schema\":\"fable-monitor.preflight/1\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"category\":\"source_schema\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"status\":\"fail\"") != null);
    try testing.expect(!preflightChecksOk(&checks));
}

test "an absent observation rearms a model restoration episode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = testContext(a, 3_000);
    const src = Source{ .id = "list", .kind = .model_list_probe, .tier = .tier1, .url = "", .label = "", .match = &.{"claude-fable-5"} };
    const prev = State{ .source_status = @constCast(&[_]State.SourceStatus{
        .{ .id = "list", .last_poll_ms = 1_000, .last_success_ms = 1_000 },
    }) };
    var r = Run{ .ctx = &ctx, .opts = .{}, .cfg = .{ .sources = @constCast(&[_]Source{src}) }, .prev = prev };
    try r.successful.append(a, src.id);
    try r.alerts.append(a, .{ .event_identity = "model_present:claude-fable-5", .epoch_ms = 1_000 });
    try rearmEndedEpisodes(&r);
    try testing.expectEqual(@as(usize, 0), r.alerts.items.len);

    try detectModelList(&r, src, "<li>claude-fable-5</li>");
    try testing.expectEqual(@as(usize, 1), r.signals.items.len);
}

test "notifier nonzero exit is a delivery failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var ctx = testContext(arena_state.allocator(), 0);
    ctx.notify_cmd = "exit 9";
    try testing.expectError(error.NotifyFailed, runNotify(&ctx, "message"));
}

test "sink outage remains pending across reload and retries with the same occurrence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const state_path = ".test-fable-monitor-delivery-state.zst";
    const backup_path = ".test-fable-monitor-delivery-state.zst.backup";
    const sink_path = ".test-fable-monitor-delivery-sink.jsonl";
    const lock_path = ".test-fable-monitor-delivery-state.zst.lock";
    defer Io.Dir.cwd().deleteFile(testing.io, state_path) catch {};
    defer Io.Dir.cwd().deleteFile(testing.io, backup_path) catch {};
    defer Io.Dir.cwd().deleteFile(testing.io, sink_path) catch {};
    defer Io.Dir.cwd().deleteFile(testing.io, lock_path) catch {};

    var ctx = testContext(a, 10_000);
    ctx.state_path = state_path;
    const occurrence = "occ-stable-1";
    const payload =
        \\{"schema":"fable-monitor.event/1","event_id":"logical","occurrence_id":"occ-stable-1","idempotency_key":"occ-stable-1"}
    ;
    try state_mod.saveState(&ctx, .{
        .version = state_mod.current_version,
        .alerts = @constCast(&[_]State.AlertRecord{.{
            .event_identity = "logical",
            .occurrence_id = occurrence,
            .epoch_ms = 10_000,
            .delivered = false,
        }}),
        .deliveries = @constCast(&[_]State.DeliveryRecord{.{
            .occurrence_id = occurrence,
            .event_identity = "logical",
            .sink = "event_sink",
            .payload = payload,
        }}),
    });

    try testing.expectError(error.DeliveryPending, deliverPending(&ctx, .{}, false, null));
    const failed = try state_mod.loadState(&ctx);
    try testing.expectEqual(@as(u32, 1), failed.deliveries[0].attempts);
    try testing.expect(!failed.deliveries[0].delivered);
    try testing.expectEqualStrings(occurrence, failed.deliveries[0].occurrence_id);
    try testing.expectEqualStrings("EventSinkNotConfigured", failed.deliveries[0].last_error);

    ctx.epoch_ms = failed.deliveries[0].next_retry_ms + 1;
    try deliverPending(&ctx, .{ .event_sink_path = sink_path }, false, null);
    const delivered = try state_mod.loadState(&ctx);
    try testing.expectEqual(@as(usize, 0), delivered.deliveries.len);
    try testing.expect(delivered.alerts[0].delivered);

    // Re-running inspection/retry cannot append a second logical event.
    try deliverPending(&ctx, .{ .event_sink_path = sink_path }, true, null);
    const sink = try Io.Dir.cwd().readFileAlloc(testing.io, sink_path, a, .limited(4096));
    try testing.expect(try eventSinkHasOccurrence(a, sink, occurrence));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink, "\n"));
}

test "late failure cannot overwrite a newer claimant success" {
    var deliveries = [_]State.DeliveryRecord{.{
        .occurrence_id = "occ-race",
        .event_identity = "logical",
        .sink = "webhook",
        .payload = "payload",
        .lease_until_ms = 20_000,
        .lease_token = "worker-b",
    }};
    const st = State{ .version = state_mod.current_version, .deliveries = &deliveries };
    const worker_a = State.DeliveryRecord{
        .occurrence_id = "occ-race",
        .event_identity = "logical",
        .sink = "webhook",
        .payload = "payload",
        .lease_until_ms = 10_000,
        .lease_token = "worker-a",
    };
    const worker_b = deliveries[0];

    try testing.expect(applyDeliveryCompletion(st, worker_b, null, 15_000));
    try testing.expect(deliveries[0].delivered);
    try testing.expectEqual(@as(u32, 1), deliveries[0].attempts);
    try testing.expect(!applyDeliveryCompletion(st, worker_a, error.WebhookFailed, 16_000));
    try testing.expect(deliveries[0].delivered);
    try testing.expectEqual(@as(u32, 1), deliveries[0].attempts);
    try testing.expectEqualStrings("", deliveries[0].last_error);
}

test "JSON content type accepts parameters and structured suffixes" {
    try testing.expect(isJsonContentType("application/json"));
    try testing.expect(isJsonContentType("Application/JSON; charset=utf-8"));
    try testing.expect(isJsonContentType("application/problem+json"));
    try testing.expect(!isJsonContentType("text/html"));
    try testing.expect(!isJsonContentType(""));
}
