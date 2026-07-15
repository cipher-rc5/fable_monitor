//! The persisted monitor state. Serialized as line-delimited JSON, zstd-
//! compressed on disk. Each line is one `StateRecord`, tagged by `kind`.
//!
//! Format versioning: v1 wrote only `seen` and `hash` records and no `meta`
//! line. v2 adds a leading `meta` record carrying `state_version`, plus
//! `validator` (conditional-request ETag/Last-Modified), `model` (model ids
//! currently present per probe source), `feed` (seen feed-entry keys),
//! `status` (per-source timing for cadence and the coverage audit), and `alert`
//! (alert-once / escalation bookkeeping) records. A v1 file loads unchanged: the
//! absent `meta` defaults `version` to 1 and the unknown-to-v1 record kinds
//! simply never appear. Future versions and unknown record kinds fail closed.
//!
//! v3 adds `term` records: the restoration terms present (negation-aware) on a
//! statement source at its last poll — the baseline an absent-to-present term
//! transition is detected against. A v1/v2 file loads unchanged; its missing
//! term records read as "term baseline unknown" (`version <
//! term_records_version`), which the statement detector treats as
//! re-baseline-without-tripping rather than an unknowable transition.
//!
//! v4 adds durable `delivery` records and occurrence/delivery fields on alerts.
//! v1-v3 alerts are treated as already delivered because those versions only
//! wrote an alert after their synchronous delivery path returned.
//!
//! v5 adds random lease tokens that fence delivery completion. A v4 lease has
//! no claimant token and is cleared when that state is next saved.
//!
//! Parsing fails closed on malformed records, unknown record kinds, and format
//! versions newer than this binary. Such a generation is never overwritten by
//! `saveState`; a caller must explicitly quarantine it first.

const std = @import("std");
const Io = std.Io;
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;
const zstd = @import("zstd.zig");
const events_mod = @import("events.zig");

/// The current on-disk state format version written by `saveState`.
pub const current_version: u32 = 5;

/// The first format version whose files carry `term` records. A loaded state
/// older than this has no restoration-term baseline: the statement detector
/// must re-baseline the term set instead of trusting an unknowable transition.
pub const term_records_version: u32 = 3;

/// Settled alert records (acknowledged or already escalated) older than this
/// window are pruned on save, so the alert list does not grow monotonically.
/// Unsettled alerts are kept regardless of age — they may still escalate.
pub const alert_retention_ms: i64 = 90 * std.time.ms_per_day;

/// True when an alert record is settled and old enough to drop on save.
pub fn alertExpired(a: State.AlertRecord, now_ms: i64) bool {
    if (!a.acknowledged and !a.escalated) return false;
    return now_ms - a.epoch_ms > alert_retention_ms;
}

pub const State = struct {
    version: u32 = 1, // 1 when loaded from a pre-meta (v1) file
    federal_register_seen: [][]const u8 = &.{},
    keyword_hashes: []KeywordHash = &.{},
    validators: []Validator = &.{},
    model_present: []ModelPresent = &.{},
    terms_present: []TermPresent = &.{},
    feed_seen: []FeedSeen = &.{},
    source_status: []SourceStatus = &.{},
    alerts: []AlertRecord = &.{},
    deliveries: []DeliveryRecord = &.{},

    pub const KeywordHash = struct {
        id: []const u8,
        hash: []const u8,
    };

    /// Cached conditional-request validators for a source, so the next poll can
    /// send If-None-Match / If-Modified-Since and get a cheap 304.
    pub const Validator = struct {
        id: []const u8,
        etag: []const u8 = "",
        last_modified: []const u8 = "",
    };

    /// One (source, model id) pair observed present in a model listing. The set
    /// of these is what an absent-to-present transition is detected against.
    pub const ModelPresent = struct {
        id: []const u8, // source id
        model: []const u8, // model identifier seen present
    };

    /// One (source, restoration-term) pair observed present — negation-aware,
    /// see `sources.presentOutsideNegation` — on a statement page. The set of
    /// these is the baseline an absent-to-present term transition (the
    /// statement_watch trip condition) is detected against.
    pub const TermPresent = struct {
        id: []const u8, // source id
        term: []const u8, // restoration term seen present
    };

    /// One (source, entry-key) pair already seen in a feed, so re-seeing it is
    /// not a change. Keys are guids / links / sitemap loc URLs.
    pub const FeedSeen = struct {
        id: []const u8, // source id
        key: []const u8,
    };

    /// Per-source timing, for adaptive cadence (is this source due?) and the
    /// coverage audit (is a source quietly dead?).
    pub const SourceStatus = struct {
        id: []const u8,
        last_poll_ms: i64 = 0, // last attempt
        last_success_ms: i64 = 0, // last successful fetch
        last_change_ms: i64 = 0, // last time a change was detected
    };

    /// Alert-once / escalation bookkeeping, keyed on a normalized event
    /// identity so one real event alerts once even as it persists across polls.
    /// Carries enough of the original event (tier, kind, title, url) to re-emit
    /// an escalation later without the underlying signal having to re-appear.
    pub const AlertRecord = struct {
        event_identity: []const u8,
        occurrence_id: []const u8 = "",
        epoch_ms: i64 = 0, // when first alerted
        delivered: bool = true,
        acknowledged: bool = false,
        escalated: bool = false,
        tier: u8 = 0,
        ev_kind: []const u8 = "",
        title: []const u8 = "",
        url: []const u8 = "",
    };

    /// One required sink for one immutable occurrence. Pending records remain
    /// in the snapshot until that sink succeeds; a lease lets delivery happen
    /// outside the state lock without concurrent workers taking the same item.
    pub const DeliveryRecord = struct {
        occurrence_id: []const u8,
        event_identity: []const u8,
        sink: []const u8,
        payload: []const u8,
        notify_message: []const u8 = "",
        attempts: u32 = 0,
        next_retry_ms: i64 = 0,
        lease_until_ms: i64 = 0,
        lease_token: []const u8 = "",
        last_error: []const u8 = "",
        delivered: bool = false,
    };

    pub fn hashFor(self: State, id: []const u8) ?[]const u8 {
        for (self.keyword_hashes) |kh| {
            if (std.mem.eql(u8, kh.id, id)) return kh.hash;
        }
        return null;
    }

    pub fn hasSeen(self: State, doc: []const u8) bool {
        for (self.federal_register_seen) |d| {
            if (std.mem.eql(u8, d, doc)) return true;
        }
        return false;
    }

    pub fn validatorFor(self: State, id: []const u8) ?Validator {
        for (self.validators) |v| {
            if (std.mem.eql(u8, v.id, id)) return v;
        }
        return null;
    }

    pub fn modelIsPresent(self: State, source_id: []const u8, model: []const u8) bool {
        for (self.model_present) |m| {
            if (std.mem.eql(u8, m.id, source_id) and std.mem.eql(u8, m.model, model)) return true;
        }
        return false;
    }

    pub fn termIsPresent(self: State, source_id: []const u8, term: []const u8) bool {
        for (self.terms_present) |t| {
            if (std.mem.eql(u8, t.id, source_id) and std.mem.eql(u8, t.term, term)) return true;
        }
        return false;
    }

    pub fn feedHasSeen(self: State, source_id: []const u8, key: []const u8) bool {
        for (self.feed_seen) |f| {
            if (std.mem.eql(u8, f.id, source_id) and std.mem.eql(u8, f.key, key)) return true;
        }
        return false;
    }

    pub fn statusFor(self: State, id: []const u8) ?SourceStatus {
        for (self.source_status) |s| {
            if (std.mem.eql(u8, s.id, id)) return s;
        }
        return null;
    }

    pub fn alertFor(self: State, identity: []const u8) ?AlertRecord {
        for (self.alerts) |a| {
            if (std.mem.eql(u8, a.event_identity, identity)) return a;
        }
        return null;
    }

    pub const DeliveryCounts = struct { pending: usize = 0, failed: usize = 0 };

    pub fn deliveryCounts(self: State) DeliveryCounts {
        var counts: DeliveryCounts = .{};
        for (self.deliveries) |delivery| {
            if (delivery.delivered) continue;
            counts.pending += 1;
            if (delivery.last_error.len > 0) counts.failed += 1;
        }
        return counts;
    }

    pub fn pendingDeliveries(self: State) usize {
        return self.deliveryCounts().pending;
    }
};

// The state file is line-delimited JSON: one `StateRecord` per line, tagged by
// `kind`. The struct is the union of every record kind's fields. Extra fields
// remain forward-compatible within a known format version, but malformed or
// unknown records fail the entire load rather than yielding partial state.
pub const StateRecord = struct {
    kind: []const u8 = "",
    version: u32 = 0,
    document_number: []const u8 = "",
    id: []const u8 = "",
    hash: []const u8 = "",
    etag: []const u8 = "",
    last_modified: []const u8 = "",
    model: []const u8 = "",
    term: []const u8 = "",
    key: []const u8 = "",
    event_identity: []const u8 = "",
    occurrence_id: []const u8 = "",
    sink: []const u8 = "",
    payload: []const u8 = "",
    notify_message: []const u8 = "",
    attempts: u32 = 0,
    next_retry_ms: i64 = 0,
    lease_until_ms: i64 = 0,
    lease_token: []const u8 = "",
    last_error: []const u8 = "",
    delivered: bool = false,
    epoch_ms: i64 = 0,
    last_poll_ms: i64 = 0,
    last_success_ms: i64 = 0,
    last_change_ms: i64 = 0,
    acknowledged: bool = false,
    escalated: bool = false,
    tier: u8 = 0,
    ev_kind: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
};

/// Payload-free parse details suitable for logs and operator-facing APIs. The
/// diagnostic intentionally reports only structural information, never the
/// malformed record or any of its fields.
pub const ParseDiagnostic = struct {
    line: usize = 0,
    reason: Reason = .none,

    pub const Reason = enum {
        none,
        empty_state,
        malformed_json,
        invalid_field,
        duplicate_record,
        invalid_order,
        unsupported_version,
        unsupported_record,
    };
};

pub const StateInspection = struct {
    status: Status,
    version: u32 = 0,
    diagnostic: ParseDiagnostic = .{},

    pub const Status = enum {
        missing,
        valid,
        corrupt_compression,
        malformed,
        unsupported_version,
        unsupported_record,
    };
};

/// Read and decode the state file: zstd-decompress, then parse one
/// `StateRecord` per line back into a `State`. All errors, including
/// `FileNotFound`, propagate unchanged so the caller decides recovery policy.
pub fn loadState(ctx: *Context) !State {
    const raw = try Io.Dir.cwd().readFileAlloc(
        ctx.io,
        ctx.state_path,
        ctx.arena,
        .limited(64 * 1024 * 1024),
    );
    const data = try zstd.decompress(ctx.io, ctx.arena, raw);
    return parse(ctx.arena, data);
}

/// Validate the active generation without exposing record contents. Expected
/// state-format failures are returned as status values; environmental I/O and
/// allocation failures still propagate as errors.
pub fn inspectState(ctx: *Context) !StateInspection {
    const raw = Io.Dir.cwd().readFileAlloc(
        ctx.io,
        ctx.state_path,
        ctx.arena,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .status = .missing },
        else => return err,
    };
    const data = zstd.decompress(ctx.io, ctx.arena, raw) catch |err| switch (err) {
        error.ZstdFailed => return .{ .status = .corrupt_compression },
        else => return err,
    };
    var diagnostic: ParseDiagnostic = .{};
    const state = parseDiagnostic(ctx.arena, data, &diagnostic) catch |err| return .{
        .status = switch (err) {
            error.UnsupportedStateVersion => .unsupported_version,
            error.UnsupportedStateRecord => .unsupported_record,
            error.MalformedState => .malformed,
            else => return err,
        },
        .diagnostic = diagnostic,
    };
    return .{ .status = .valid, .version = state.version };
}

/// Parse the decompressed NDJSON body into a `State`. Split out from
/// `loadState` so it can be unit-tested without touching disk or zstd.
pub fn parse(arena: std.mem.Allocator, data: []const u8) !State {
    var diagnostic: ParseDiagnostic = .{};
    return parseDiagnostic(arena, data, &diagnostic);
}

/// Parse state while returning a safe line-numbered diagnostic on failure.
pub fn parseDiagnostic(arena: std.mem.Allocator, data: []const u8, diagnostic: *ParseDiagnostic) !State {
    diagnostic.* = .{};
    var version: u32 = 1;
    var seen: std.ArrayList([]const u8) = .empty;
    var hashes: std.ArrayList(State.KeywordHash) = .empty;
    var validators: std.ArrayList(State.Validator) = .empty;
    var models: std.ArrayList(State.ModelPresent) = .empty;
    var terms: std.ArrayList(State.TermPresent) = .empty;
    var feeds: std.ArrayList(State.FeedSeen) = .empty;
    var statuses: std.ArrayList(State.SourceStatus) = .empty;
    var alerts: std.ArrayList(State.AlertRecord) = .empty;
    var deliveries: std.ArrayList(State.DeliveryRecord) = .empty;
    var record_count: usize = 0;
    var meta_seen = false;
    var line_number: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        // Leaky parse into the caller's arena: parseFromSlice would wrap each
        // record in its own owned ArenaAllocator that this code never deinits,
        // stranding that arena until the caller's arena is torn down (and, under
        // a partial allocation failure, leaking it). The caller's arena owns the
        // record's lifetime, so parse directly into it.
        const r = std.json.parseFromSliceLeaky(StateRecord, arena, t, .{ .ignore_unknown_fields = true }) catch
            return parseFailure(diagnostic, line_number, .malformed_json, error.MalformedState);
        if (std.mem.eql(u8, r.kind, "meta")) {
            if (record_count != 0 or meta_seen) return parseFailure(diagnostic, line_number, .invalid_order, error.MalformedState);
            if (r.version == 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            if (r.version > current_version) return parseFailure(diagnostic, line_number, .unsupported_version, error.UnsupportedStateVersion);
            version = r.version;
            meta_seen = true;
        } else if (std.mem.eql(u8, r.kind, "seen")) {
            if (r.document_number.len == 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            try seen.append(arena, r.document_number);
        } else if (std.mem.eql(u8, r.kind, "hash")) {
            if (r.id.len == 0 or r.hash.len == 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            for (hashes.items) |existing| if (std.mem.eql(u8, existing.id, r.id)) return parseFailure(diagnostic, line_number, .duplicate_record, error.MalformedState);
            try hashes.append(arena, .{ .id = r.id, .hash = r.hash });
        } else if (std.mem.eql(u8, r.kind, "validator")) {
            if (version == 1 or r.id.len == 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            for (validators.items) |existing| if (std.mem.eql(u8, existing.id, r.id)) return parseFailure(diagnostic, line_number, .duplicate_record, error.MalformedState);
            try validators.append(arena, .{ .id = r.id, .etag = r.etag, .last_modified = r.last_modified });
        } else if (std.mem.eql(u8, r.kind, "model")) {
            if (version == 1 or r.id.len == 0 or r.model.len == 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            try models.append(arena, .{ .id = r.id, .model = r.model });
        } else if (std.mem.eql(u8, r.kind, "term")) {
            if (version < term_records_version or r.id.len == 0 or r.term.len == 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            try terms.append(arena, .{ .id = r.id, .term = r.term });
        } else if (std.mem.eql(u8, r.kind, "feed")) {
            if (version == 1 or r.id.len == 0 or r.key.len == 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            try feeds.append(arena, .{ .id = r.id, .key = r.key });
        } else if (std.mem.eql(u8, r.kind, "status")) {
            if (version == 1 or r.id.len == 0 or r.last_poll_ms < 0 or r.last_success_ms < 0 or r.last_change_ms < 0 or
                (version >= 5 and (r.last_success_ms > r.last_poll_ms or r.last_change_ms > r.last_poll_ms)))
                return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            for (statuses.items) |existing| if (std.mem.eql(u8, existing.id, r.id)) return parseFailure(diagnostic, line_number, .duplicate_record, error.MalformedState);
            try statuses.append(arena, .{
                .id = r.id,
                .last_poll_ms = r.last_poll_ms,
                .last_success_ms = r.last_success_ms,
                .last_change_ms = r.last_change_ms,
            });
        } else if (std.mem.eql(u8, r.kind, "alert")) {
            if (version == 1 or r.event_identity.len == 0 or r.epoch_ms < 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            for (alerts.items) |existing| if (std.mem.eql(u8, existing.event_identity, r.event_identity)) return parseFailure(diagnostic, line_number, .duplicate_record, error.MalformedState);
            const occurrence_id = if (version < 4)
                try legacyOccurrenceId(arena, r.event_identity, r.epoch_ms)
            else blk: {
                if (r.occurrence_id.len == 0) return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
                break :blk r.occurrence_id;
            };
            try alerts.append(arena, .{
                .event_identity = r.event_identity,
                .occurrence_id = occurrence_id,
                .epoch_ms = r.epoch_ms,
                .delivered = if (version < 4) true else r.delivered,
                .acknowledged = r.acknowledged,
                .escalated = r.escalated,
                .tier = r.tier,
                .ev_kind = r.ev_kind,
                .title = r.title,
                .url = r.url,
            });
        } else if (std.mem.eql(u8, r.kind, "delivery")) {
            if (version < 4 or r.occurrence_id.len == 0 or r.event_identity.len == 0 or
                !validSink(r.sink) or r.payload.len == 0 or r.next_retry_ms < 0 or r.lease_until_ms < 0 or
                (std.mem.eql(u8, r.sink, "notify") and r.notify_message.len == 0) or
                (r.delivered and (r.next_retry_ms != 0 or r.lease_until_ms != 0 or r.lease_token.len != 0 or r.last_error.len != 0)) or
                (version >= 5 and (r.lease_until_ms == 0) != (r.lease_token.len == 0)) or
                !validDeliveryPayload(arena, r.payload, r.event_identity, r.occurrence_id))
                return parseFailure(diagnostic, line_number, .invalid_field, error.MalformedState);
            for (deliveries.items) |existing| {
                if (std.mem.eql(u8, existing.occurrence_id, r.occurrence_id) and std.mem.eql(u8, existing.sink, r.sink))
                    return parseFailure(diagnostic, line_number, .duplicate_record, error.MalformedState);
            }
            try deliveries.append(arena, .{
                .occurrence_id = r.occurrence_id,
                .event_identity = r.event_identity,
                .sink = r.sink,
                .payload = r.payload,
                .notify_message = r.notify_message,
                .attempts = r.attempts,
                .next_retry_ms = r.next_retry_ms,
                .lease_until_ms = r.lease_until_ms,
                .lease_token = r.lease_token,
                .last_error = r.last_error,
                .delivered = r.delivered,
            });
        } else {
            return parseFailure(diagnostic, line_number, .unsupported_record, error.UnsupportedStateRecord);
        }
        record_count += 1;
    }
    if (record_count == 0) return parseFailure(diagnostic, 0, .empty_state, error.MalformedState);
    return .{
        .version = version,
        .federal_register_seen = seen.items,
        .keyword_hashes = hashes.items,
        .validators = validators.items,
        .model_present = models.items,
        .terms_present = terms.items,
        .feed_seen = feeds.items,
        .source_status = statuses.items,
        .alerts = alerts.items,
        .deliveries = deliveries.items,
    };
}

fn parseFailure(diagnostic: *ParseDiagnostic, line: usize, reason: ParseDiagnostic.Reason, err: anyerror) anyerror {
    diagnostic.* = .{ .line = line, .reason = reason };
    return err;
}

fn validSink(sink: []const u8) bool {
    return std.mem.eql(u8, sink, "stdout") or std.mem.eql(u8, sink, "event_sink") or
        std.mem.eql(u8, sink, "webhook") or std.mem.eql(u8, sink, "notify");
}

fn validDeliveryPayload(arena: std.mem.Allocator, payload: []const u8, identity: []const u8, occurrence_id: []const u8) bool {
    const Key = struct {
        event_id: []const u8,
        occurrence_id: []const u8,
        idempotency_key: []const u8,
    };
    const parsed = std.json.parseFromSlice(Key, arena, payload, .{ .ignore_unknown_fields = true }) catch return false;
    return std.mem.eql(u8, parsed.value.event_id, identity) and
        std.mem.eql(u8, parsed.value.occurrence_id, occurrence_id) and
        std.mem.eql(u8, parsed.value.idempotency_key, occurrence_id);
}

fn legacyOccurrenceId(arena: std.mem.Allocator, identity: []const u8, epoch_ms: i64) ![]const u8 {
    const digest = std.hash.Wyhash.hash(0, identity);
    return std.fmt.allocPrint(arena, "legacy-{x:0>16}-{d}", .{ digest, epoch_ms });
}

/// The advisory inter-process lock serializing every state read-modify-write
/// (poll and ack), taken on a `.lock` file next to the state path so an
/// overlapping cron poll or a concurrent ack cannot discard each other's
/// writes. flock semantics: the lock is released automatically when the
/// process exits, so a crash never wedges the monitor.
pub const StateLock = struct {
    file: Io.File,

    pub fn release(self: *StateLock, io: Io) void {
        self.file.close(io); // closing the descriptor drops the flock
    }
};

/// How long `acquireLock` waits on a competing holder before failing loudly,
/// and the pause between nonblocking attempts.
const lock_wait_ms: i64 = 5000;
const lock_retry_ms: i64 = 100;

/// Take the exclusive advisory lock on `<state_path>.lock`, blocking briefly
/// (nonblocking flock retried up to `lock_wait_ms`) and then failing with
/// `error.StateLockHeld` rather than deadlocking forever.
pub fn acquireLock(ctx: *Context) !StateLock {
    const lock_path = try std.fmt.allocPrint(ctx.arena, "{s}.lock", .{ctx.state_path});
    var waited: i64 = 0;
    while (true) {
        const file = Io.Dir.cwd().createFile(ctx.io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock => {
                if (waited >= lock_wait_ms) {
                    log("error: state lock {s} still held after {d}ms; is another poll/ack running?", .{ lock_path, waited });
                    return error.StateLockHeld;
                }
                Io.sleep(ctx.io, Io.Duration.fromMilliseconds(lock_retry_ms), .awake) catch {};
                waited += lock_retry_ms;
                continue;
            },
            else => return err,
        };
        errdefer file.close(ctx.io);
        try file.setPermissions(ctx.io, .fromMode(0o600));
        return .{ .file = file };
    }
}

/// Move the current state generation aside for operator-directed recovery.
/// The caller must hold `StateLock`. The returned arena-owned path can be
/// reported for inspection or later restoration.
pub fn quarantineState(ctx: *Context) ![]const u8 {
    var rnd: [8]u8 = undefined;
    Io.random(ctx.io, &rnd);
    const quarantine_path = try std.fmt.allocPrint(ctx.arena, "{s}.corrupt.{x}", .{
        ctx.state_path,
        std.mem.readInt(u64, &rnd, .little),
    });
    {
        var file = try Io.Dir.cwd().openFile(ctx.io, ctx.state_path, .{ .mode = .read_only });
        defer file.close(ctx.io);
        try file.setPermissions(ctx.io, .fromMode(0o600));
    }
    try Io.Dir.cwd().rename(ctx.state_path, .cwd(), quarantine_path, ctx.io);
    try events_mod.syncParentDir(ctx.io, ctx.state_path);
    return quarantine_path;
}

/// Stable companion paths let operators and a future CLI locate recovery
/// artifacts without scanning random quarantine names.
pub fn backupPath(arena: std.mem.Allocator, state_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.backup", .{state_path});
}

pub fn recoveryAuditPath(arena: std.mem.Allocator, state_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.recovery.json", .{state_path});
}

pub const RecoveryResult = struct {
    action: Action,
    quarantine_path: ?[]const u8,
    backup_path: ?[]const u8,
    restored_version: u32 = 0,

    pub const Action = enum { recover_backup, rebaseline };
};

const RecoveryAudit = struct {
    action: []const u8,
    epoch_ms: i64,
    state_version: u32,
    backup_path: ?[]const u8 = null,
    quarantine_path: ?[]const u8 = null,
};

fn writeRecoveryAudit(ctx: *Context, audit: RecoveryAudit) !void {
    const path = try recoveryAuditPath(ctx.arena, ctx.state_path);
    const data = try std.json.Stringify.valueAlloc(ctx.arena, audit, .{ .emit_strings_as_arrays = false });
    try events_mod.writeFileAtomic(ctx.io, ctx.arena, path, data);
}

fn validateCompressedState(ctx: *Context, raw: []const u8) !State {
    const data = try zstd.decompress(ctx.io, ctx.arena, raw);
    var diagnostic: ParseDiagnostic = .{};
    return parseDiagnostic(ctx.arena, data, &diagnostic);
}

/// Restore the fixed last-known-good backup. The backup is validated before
/// the active generation is touched, and the active bytes are quarantined
/// rather than deleted. The restored file is byte-for-byte equal to `.backup`.
/// The caller must hold `StateLock`.
pub fn recoverState(ctx: *Context) !RecoveryResult {
    const backup_path = try backupPath(ctx.arena, ctx.state_path);
    const raw = try Io.Dir.cwd().readFileAlloc(ctx.io, backup_path, ctx.arena, .limited(64 * 1024 * 1024));
    const restored = try validateCompressedState(ctx, raw);

    const quarantine_path: ?[]const u8 = quarantineState(ctx) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    try events_mod.writeFileAtomic(ctx.io, ctx.arena, ctx.state_path, raw);
    try writeRecoveryAudit(ctx, .{
        .action = "recover_backup",
        .epoch_ms = ctx.epoch_ms,
        .state_version = restored.version,
        .backup_path = backup_path,
        .quarantine_path = quarantine_path,
    });
    return .{
        .action = .recover_backup,
        .quarantine_path = quarantine_path,
        .backup_path = backup_path,
        .restored_version = restored.version,
    };
}

/// Preserve the active generation and leave the state path absent so the next
/// poll establishes a fresh baseline. The caller must hold `StateLock`.
pub fn rebaselineState(ctx: *Context) !RecoveryResult {
    const quarantine_path: ?[]const u8 = quarantineState(ctx) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    try writeRecoveryAudit(ctx, .{
        .action = "rebaseline",
        .epoch_ms = ctx.epoch_ms,
        .state_version = current_version,
        .quarantine_path = quarantine_path,
    });
    return .{
        .action = .rebaseline,
        .quarantine_path = quarantine_path,
        .backup_path = null,
    };
}

fn validateExistingState(ctx: *Context) !?[]const u8 {
    const raw = Io.Dir.cwd().readFileAlloc(
        ctx.io,
        ctx.state_path,
        ctx.arena,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    _ = try validateCompressedState(ctx, raw);
    return raw;
}

/// Serialize `state` as line-delimited JSON records, zstd-compress, and write
/// the result to the state file (a full rewrite, staged through a temp file
/// and renamed into place so a crash never leaves a torn state). Writes a
/// leading `meta` record stamping the current format version, and prunes
/// settled alert records past `alert_retention_ms`. An existing generation is
/// validated and atomically retained as `.backup` first, preventing malformed
/// or future state from being replaced and preserving one rollback generation.
pub fn saveState(ctx: *Context, state: State) !void {
    return saveStateImpl(ctx, state, false);
}

fn saveStateImpl(ctx: *Context, state: State, inject_failure_after_backup: bool) !void {
    if (state.version > current_version) return error.UnsupportedStateVersion;
    const previous = try validateExistingState(ctx);

    var buf: std.ArrayList(u8) = .empty;
    try writeRecord(ctx.arena, &buf, .{ .kind = "meta", .version = current_version });
    for (state.federal_register_seen) |d| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "seen", .document_number = d });
    }
    for (state.keyword_hashes) |kh| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "hash", .id = kh.id, .hash = kh.hash });
    }
    for (state.validators) |v| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "validator", .id = v.id, .etag = v.etag, .last_modified = v.last_modified });
    }
    for (state.model_present) |m| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "model", .id = m.id, .model = m.model });
    }
    for (state.terms_present) |t| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "term", .id = t.id, .term = t.term });
    }
    for (state.feed_seen) |f| {
        try writeRecord(ctx.arena, &buf, .{ .kind = "feed", .id = f.id, .key = f.key });
    }
    for (state.source_status) |s| {
        try writeRecord(ctx.arena, &buf, .{
            .kind = "status",
            .id = s.id,
            // Older states may carry a change/success later than last_poll due
            // to the pre-v5 detector/status ordering bug. Preserve the times
            // while restoring the v5 ordering invariant during migration.
            .last_poll_ms = @max(s.last_poll_ms, s.last_success_ms, s.last_change_ms),
            .last_success_ms = s.last_success_ms,
            .last_change_ms = s.last_change_ms,
        });
    }
    for (state.alerts) |a| {
        if (alertExpired(a, ctx.epoch_ms)) continue;
        try writeRecord(ctx.arena, &buf, .{
            .kind = "alert",
            .event_identity = a.event_identity,
            .occurrence_id = a.occurrence_id,
            .epoch_ms = a.epoch_ms,
            .delivered = a.delivered,
            .acknowledged = a.acknowledged,
            .escalated = a.escalated,
            .tier = a.tier,
            .ev_kind = a.ev_kind,
            .title = a.title,
            .url = a.url,
        });
    }
    for (state.deliveries) |delivery| {
        if (delivery.delivered and occurrenceSettled(state.deliveries, delivery.occurrence_id)) continue;
        // A v4 lease has no token identifying its claimant. Expire it during
        // migration rather than creating an unfenced v5 lease.
        const lease_until_ms = if (delivery.lease_token.len == 0) 0 else delivery.lease_until_ms;
        try writeRecord(ctx.arena, &buf, .{
            .kind = "delivery",
            .occurrence_id = delivery.occurrence_id,
            .event_identity = delivery.event_identity,
            .sink = delivery.sink,
            .payload = delivery.payload,
            .notify_message = delivery.notify_message,
            .attempts = delivery.attempts,
            .next_retry_ms = delivery.next_retry_ms,
            .lease_until_ms = lease_until_ms,
            .lease_token = delivery.lease_token,
            .last_error = delivery.last_error,
            .delivered = delivery.delivered,
        });
    }

    // Refuse to commit a generation that this binary could not load back.
    _ = try parse(ctx.arena, buf.items);
    const compressed = try zstd.compress(ctx.io, ctx.arena, buf.items);
    if (previous) |last_known_good| {
        const backup_path = try backupPath(ctx.arena, ctx.state_path);
        try events_mod.writeFileAtomic(ctx.io, ctx.arena, backup_path, last_known_good);
        if (inject_failure_after_backup) return error.InjectedWriteFailure;
    }
    try events_mod.writeFileAtomic(ctx.io, ctx.arena, ctx.state_path, compressed);
    log("state written to {s} (v{d}, {d} bytes compressed)", .{ ctx.state_path, current_version, compressed.len });
}

fn occurrenceSettled(deliveries: []const State.DeliveryRecord, occurrence_id: []const u8) bool {
    var found = false;
    for (deliveries) |delivery| {
        if (!std.mem.eql(u8, delivery.occurrence_id, occurrence_id)) continue;
        found = true;
        if (!delivery.delivered) return false;
    }
    return found;
}

/// Stringify one record (omitting empty/zero fields keeps lines compact) and
/// append it plus a newline to `buf`.
fn writeRecord(arena: std.mem.Allocator, buf: *std.ArrayList(u8), rec: StateRecord) !void {
    const line = try std.json.Stringify.valueAlloc(arena, rec, .{ .emit_strings_as_arrays = false });
    try buf.appendSlice(arena, line);
    try buf.append(arena, '\n');
}

/// Keep only the most recent `max` entries (the tail), so the seen-document
/// list does not grow without bound across runs.
pub fn capTail(items: [][]const u8, max: usize) [][]const u8 {
    if (items.len <= max) return items;
    return items[items.len - max ..];
}

const testing = std.testing;

test "alertExpired prunes only settled alerts past the retention window" {
    const now: i64 = alert_retention_ms + 1_000_000;
    const old_ack = State.AlertRecord{ .event_identity = "a", .epoch_ms = 1, .acknowledged = true };
    const old_esc = State.AlertRecord{ .event_identity = "b", .epoch_ms = 1, .escalated = true };
    const old_open = State.AlertRecord{ .event_identity = "c", .epoch_ms = 1 };
    const new_ack = State.AlertRecord{ .event_identity = "d", .epoch_ms = now - 1000, .acknowledged = true };
    try testing.expect(alertExpired(old_ack, now));
    try testing.expect(alertExpired(old_esc, now));
    try testing.expect(!alertExpired(old_open, now)); // unsettled: kept forever
    try testing.expect(!alertExpired(new_ack, now)); // settled but recent: kept
}

test "acquireLock excludes a second holder until released" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const io = testing.io;

    var ctx = Context{
        .io = io,
        .arena = arena_state.allocator(),
        .state_path = ".test-fable-monitor-state.jsonl.zst",
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 0,
    };
    const lock_path = ".test-fable-monitor-state.jsonl.zst.lock";
    defer Io.Dir.cwd().deleteFile(io, lock_path) catch {};

    var lock = try acquireLock(&ctx);
    // While held, a nonblocking exclusive flock on the same path must refuse
    // (flock conflicts across open file descriptions, even in one process).
    try testing.expectError(error.WouldBlock, Io.Dir.cwd().createFile(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }));
    lock.release(io);

    // Released: the lock is immediately acquirable again.
    var again = try acquireLock(&ctx);
    again.release(io);
}

test "capTail keeps only the most recent entries" {
    var items = [_][]const u8{ "1", "2", "3", "4", "5" };
    const tail = capTail(&items, 3);
    try testing.expectEqual(@as(usize, 3), tail.len);
    try testing.expectEqualStrings("3", tail[0]);
    try testing.expectEqualStrings("5", tail[2]);
    try testing.expectEqual(@as(usize, 2), capTail(items[0..2], 3).len);
}

test "State lookups" {
    const st = State{
        .federal_register_seen = @constCast(&[_][]const u8{ "2026-001", "2026-002" }),
        .keyword_hashes = @constCast(&[_]State.KeywordHash{
            .{ .id = "anthropic_news", .hash = "deadbeef" },
        }),
        .model_present = @constCast(&[_]State.ModelPresent{
            .{ .id = "anthropic_model_list", .model = "claude-fable-5" },
        }),
    };
    try testing.expect(st.hasSeen("2026-001"));
    try testing.expect(!st.hasSeen("2026-999"));
    try testing.expectEqualStrings("deadbeef", st.hashFor("anthropic_news").?);
    try testing.expect(st.hashFor("missing") == null);
    try testing.expect(st.modelIsPresent("anthropic_model_list", "claude-fable-5"));
    try testing.expect(!st.modelIsPresent("anthropic_model_list", "claude-mythos-5"));
}

test "v1 file (no meta, only seen/hash) loads as version 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const data =
        \\{"kind":"seen","document_number":"2026-100"}
        \\{"kind":"hash","id":"bis_news","hash":"abc123"}
    ;
    const st = try parse(arena_state.allocator(), data);
    try testing.expectEqual(@as(u32, 1), st.version);
    try testing.expect(st.hasSeen("2026-100"));
    try testing.expectEqualStrings("abc123", st.hashFor("bis_news").?);
}

test "v2 records round-trip through parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const data =
        \\{"kind":"meta","version":2}
        \\{"kind":"validator","id":"fr_bis","etag":"\"v1\"","last_modified":"Mon, 01 Jan 2026 00:00:00 GMT"}
        \\{"kind":"model","id":"anthropic_model_list","model":"claude-fable-5"}
        \\{"kind":"feed","id":"google_news","key":"https://example.com/a"}
        \\{"kind":"status","id":"fr_bis","last_poll_ms":1000,"last_success_ms":900,"last_change_ms":0}
        \\{"kind":"alert","event_identity":"model:claude-fable-5","epoch_ms":1234,"acknowledged":false,"escalated":false}
    ;
    const st = try parse(arena_state.allocator(), data);
    try testing.expectEqual(@as(u32, 2), st.version);
    try testing.expectEqualStrings("\"v1\"", st.validatorFor("fr_bis").?.etag);
    try testing.expect(st.modelIsPresent("anthropic_model_list", "claude-fable-5"));
    try testing.expect(st.feedHasSeen("google_news", "https://example.com/a"));
    try testing.expectEqual(@as(i64, 900), st.statusFor("fr_bis").?.last_success_ms);
    try testing.expectEqual(@as(i64, 1234), st.alertFor("model:claude-fable-5").?.epoch_ms);
    try testing.expect(st.alertFor("model:claude-fable-5").?.delivered);
    try testing.expect(st.alertFor("model:claude-fable-5").?.occurrence_id.len > 0);
    // A pre-v3 file has no term records: the baseline reads as unknown.
    try testing.expect(st.version < term_records_version);
    try testing.expectEqual(@as(usize, 0), st.terms_present.len);
}

test "v4 delivery records preserve retry state and reject duplicate sink keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        \\{"kind":"meta","version":4}
        \\{"kind":"delivery","occurrence_id":"occ-1","event_identity":"logical","sink":"webhook","payload":"{\"event_id\":\"logical\",\"occurrence_id\":\"occ-1\",\"idempotency_key\":\"occ-1\"}","attempts":2,"next_retry_ms":5000,"last_error":"WebhookFailed"}
    ;
    const st = try parse(arena, data);
    try testing.expectEqual(@as(usize, 1), st.pendingDeliveries());
    try testing.expectEqual(@as(u32, 2), st.deliveries[0].attempts);
    try testing.expectEqualStrings("occ-1", st.deliveries[0].occurrence_id);

    try testing.expectError(error.MalformedState, parse(arena,
        \\{"kind":"meta","version":4}
        \\{"kind":"delivery","occurrence_id":"occ-1","event_identity":"logical","sink":"stdout","payload":"{\"event_id\":\"logical\",\"occurrence_id\":\"occ-1\",\"idempotency_key\":\"occ-1\"}"}
        \\{"kind":"delivery","occurrence_id":"occ-1","event_identity":"logical","sink":"stdout","payload":"{\"event_id\":\"logical\",\"occurrence_id\":\"occ-1\",\"idempotency_key\":\"occ-1\"}"}
    ));
}

test "v5 lease and timestamp schema invariants fail closed while v4 remains readable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload = "{\"event_id\":\"logical\",\"occurrence_id\":\"occ-1\",\"idempotency_key\":\"occ-1\"}";

    const valid = try parse(arena, try std.fmt.allocPrint(arena, "{{\"kind\":\"meta\",\"version\":5}}\n{{\"kind\":\"delivery\",\"occurrence_id\":\"occ-1\",\"event_identity\":\"logical\",\"sink\":\"stdout\",\"payload\":{f},\"lease_until_ms\":2000,\"lease_token\":\"claim-a\"}}\n", .{std.json.fmt(payload, .{})}));
    try testing.expectEqualStrings("claim-a", valid.deliveries[0].lease_token);

    try testing.expectError(error.MalformedState, parse(arena, try std.fmt.allocPrint(arena, "{{\"kind\":\"meta\",\"version\":5}}\n{{\"kind\":\"delivery\",\"occurrence_id\":\"occ-1\",\"event_identity\":\"logical\",\"sink\":\"stdout\",\"payload\":{f},\"lease_until_ms\":2000}}\n", .{std.json.fmt(payload, .{})})));
    try testing.expectError(error.MalformedState, parse(arena,
        \\{"kind":"meta","version":5}
        \\{"kind":"status","id":"source","last_poll_ms":100,"last_success_ms":101}
    ));

    // The same historical ordering and tokenless lease remain loadable as v4;
    // saveState performs the migration when it writes v5.
    const legacy = try parse(arena, try std.fmt.allocPrint(arena, "{{\"kind\":\"meta\",\"version\":4}}\n{{\"kind\":\"status\",\"id\":\"source\",\"last_poll_ms\":100,\"last_success_ms\":101}}\n{{\"kind\":\"delivery\",\"occurrence_id\":\"occ-1\",\"event_identity\":\"logical\",\"sink\":\"stdout\",\"payload\":{f},\"lease_until_ms\":2000}}\n", .{std.json.fmt(payload, .{})}));
    try testing.expectEqual(@as(u32, 4), legacy.version);
}

test "delivery counts distinguish pending failures" {
    const st = State{ .deliveries = @constCast(&[_]State.DeliveryRecord{
        .{ .occurrence_id = "a", .event_identity = "a", .sink = "stdout", .payload = "x" },
        .{ .occurrence_id = "b", .event_identity = "b", .sink = "stdout", .payload = "x", .attempts = 1, .next_retry_ms = 1, .last_error = "failed" },
        .{ .occurrence_id = "c", .event_identity = "c", .sink = "stdout", .payload = "x", .delivered = true },
    }) };
    const counts = st.deliveryCounts();
    try testing.expectEqual(@as(usize, 2), counts.pending);
    try testing.expectEqual(@as(usize, 1), counts.failed);
}

test "v3 term records parse and gate the transition baseline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const data =
        \\{"kind":"meta","version":3}
        \\{"kind":"term","id":"anthropic_statement","term":"available"}
    ;
    const st = try parse(arena_state.allocator(), data);
    try testing.expect(st.version >= term_records_version);
    try testing.expect(st.termIsPresent("anthropic_statement", "available"));
    try testing.expect(!st.termIsPresent("anthropic_statement", "restored"));
    try testing.expect(!st.termIsPresent("other_source", "available"));
}

test "term records survive a writeRecord/parse round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try writeRecord(arena, &buf, .{ .kind = "meta", .version = current_version });
    try writeRecord(arena, &buf, .{ .kind = "term", .id = "anthropic_statement", .term = "restored" });
    try writeRecord(arena, &buf, .{ .kind = "term", .id = "anthropic_statement", .term = "general license" });

    const st = try parse(arena, buf.items);
    try testing.expectEqual(current_version, st.version);
    try testing.expect(st.termIsPresent("anthropic_statement", "restored"));
    try testing.expect(st.termIsPresent("anthropic_statement", "general license"));
    try testing.expectEqual(@as(usize, 2), st.terms_present.len);
}

test "parse fails closed on malformed, unknown, and future records" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.MalformedState, parse(arena,
        \\{"kind":"seen","document_number":"ok"}
        \\not-json
    ));
    try testing.expectError(error.UnsupportedStateRecord, parse(arena,
        \\{"kind":"meta","version":3}
        \\{"kind":"future_record","value":1}
    ));
    try testing.expectError(error.UnsupportedStateVersion, parse(arena,
        \\{"kind":"meta","version":6}
    ));
    try testing.expectError(error.MalformedState, parse(arena,
        \\{"kind":"seen","document_number":"ok"}
        \\{"kind":"meta","version":3}
    ));
}

test "saveState preserves an unsupported existing generation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-future-state.zst";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const future = try zstd.compress(io, arena, "{\"kind\":\"meta\",\"version\":999}\n");
    try events_mod.writeFileAtomic(io, arena, path, future);
    const before = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    var ctx = Context{
        .io = io,
        .arena = arena,
        .state_path = path,
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 0,
    };

    try testing.expectError(error.UnsupportedStateVersion, saveState(&ctx, .{}));
    const after = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    try testing.expectEqualSlices(u8, before, after);
}

test "quarantineState preserves bytes under a recoverable name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-quarantine-state.zst";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    try events_mod.writeFileAtomic(io, arena, path, "damaged generation");

    var ctx = Context{
        .io = io,
        .arena = arena,
        .state_path = path,
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 0,
    };
    const quarantined = try quarantineState(&ctx);
    defer Io.Dir.cwd().deleteFile(io, quarantined) catch {};
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(io, path, .{}));
    const got = try Io.Dir.cwd().readFileAlloc(io, quarantined, arena, .limited(1024));
    try testing.expectEqualStrings("damaged generation", got);
}

test "parseDiagnostic reports malformed line without retaining payload" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: ParseDiagnostic = .{};

    try testing.expectError(error.MalformedState, parseDiagnostic(arena,
        \\{"kind":"meta","version":4}
        \\{"kind":"seen","document_number":"secret-value"
    , &diagnostic));
    try testing.expectEqual(@as(usize, 2), diagnostic.line);
    try testing.expectEqual(ParseDiagnostic.Reason.malformed_json, diagnostic.reason);

    try testing.expectError(error.MalformedState, parseDiagnostic(arena,
        \\{"kind":"meta","version":4}
        \\{"kind":"status","id":"source","last_poll_ms":-1}
    , &diagnostic));
    try testing.expectEqual(@as(usize, 2), diagnostic.line);
    try testing.expectEqual(ParseDiagnostic.Reason.invalid_field, diagnostic.reason);

    try testing.expectError(error.UnsupportedStateVersion, parseDiagnostic(arena,
        \\{"kind":"meta","version":999}
    , &diagnostic));
    try testing.expectEqual(@as(usize, 1), diagnostic.line);
    try testing.expectEqual(ParseDiagnostic.Reason.unsupported_version, diagnostic.reason);
}

test "inspectState classifies corrupt zstd without a payload diagnostic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-corrupt-zstd";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    try events_mod.writeFileAtomic(io, arena, path, "not a zstd stream: private contents");

    var ctx = Context{
        .io = io,
        .arena = arena,
        .state_path = path,
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 0,
    };
    const inspection = try inspectState(&ctx);
    try testing.expectEqual(StateInspection.Status.corrupt_compression, inspection.status);
    try testing.expectEqual(@as(usize, 0), inspection.diagnostic.line);
    try testing.expectEqual(ParseDiagnostic.Reason.none, inspection.diagnostic.reason);
}

test "saveState retains last-known-good and injected boundary leaves active whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-save-backup.zst";
    const backup_path = try backupPath(arena, path);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, backup_path) catch {};

    const original = try zstd.compress(io, arena,
        \\{"kind":"meta","version":4}
        \\{"kind":"seen","document_number":"generation-one"}
    );
    try events_mod.writeFileAtomic(io, arena, path, original);
    var ctx = Context{
        .io = io,
        .arena = arena,
        .state_path = path,
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 0,
    };
    const replacement = State{
        .version = current_version,
        .federal_register_seen = @constCast(&[_][]const u8{"generation-two"}),
    };

    try testing.expectError(error.InjectedWriteFailure, saveStateImpl(&ctx, replacement, true));
    const active_after_failure = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    const backup_after_failure = try Io.Dir.cwd().readFileAlloc(io, backup_path, arena, .limited(4096));
    try testing.expectEqualSlices(u8, original, active_after_failure);
    try testing.expectEqualSlices(u8, original, backup_after_failure);

    try saveState(&ctx, replacement);
    const backup_after_save = try Io.Dir.cwd().readFileAlloc(io, backup_path, arena, .limited(4096));
    try testing.expectEqualSlices(u8, original, backup_after_save);
    const loaded = try loadState(&ctx);
    try testing.expect(loaded.hasSeen("generation-two"));
}

test "recoverState restores validated backup byte-for-byte and writes audit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-recover.zst";
    const backup_path = try backupPath(arena, path);
    const audit_path = try recoveryAuditPath(arena, path);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, backup_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, audit_path) catch {};

    const backup = try zstd.compress(io, arena,
        \\{"kind":"meta","version":4}
        \\{"kind":"seen","document_number":"known-good"}
    );
    try events_mod.writeFileAtomic(io, arena, backup_path, backup);
    try events_mod.writeFileAtomic(io, arena, path, "corrupt active bytes");
    var ctx = Context{
        .io = io,
        .arena = arena,
        .state_path = path,
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 12345,
    };

    const result = try recoverState(&ctx);
    defer if (result.quarantine_path) |quarantined| Io.Dir.cwd().deleteFile(io, quarantined) catch {};
    const restored = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    const retained_backup = try Io.Dir.cwd().readFileAlloc(io, backup_path, arena, .limited(4096));
    try testing.expectEqualSlices(u8, backup, restored);
    try testing.expectEqualSlices(u8, backup, retained_backup);
    const quarantined = try Io.Dir.cwd().readFileAlloc(io, result.quarantine_path.?, arena, .limited(4096));
    try testing.expectEqualStrings("corrupt active bytes", quarantined);

    const audit_data = try Io.Dir.cwd().readFileAlloc(io, audit_path, arena, .limited(4096));
    const audit = try std.json.parseFromSlice(RecoveryAudit, arena, audit_data, .{});
    try testing.expectEqualStrings("recover_backup", audit.value.action);
    try testing.expectEqual(@as(i64, 12345), audit.value.epoch_ms);
    try testing.expectEqual(@as(u32, 4), audit.value.state_version);
}

test "rebaselineState quarantines the active generation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-rebaseline.zst";
    const audit_path = try recoveryAuditPath(arena, path);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    defer Io.Dir.cwd().deleteFile(io, audit_path) catch {};
    try events_mod.writeFileAtomic(io, arena, path, "generation to preserve");
    var ctx = Context{
        .io = io,
        .arena = arena,
        .state_path = path,
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 77,
    };

    const result = try rebaselineState(&ctx);
    defer Io.Dir.cwd().deleteFile(io, result.quarantine_path.?) catch {};
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(io, path, .{}));
    const preserved = try Io.Dir.cwd().readFileAlloc(io, result.quarantine_path.?, arena, .limited(4096));
    try testing.expectEqualStrings("generation to preserve", preserved);
    var audit_file = try Io.Dir.cwd().openFile(io, audit_path, .{});
    audit_file.close(io);
}
