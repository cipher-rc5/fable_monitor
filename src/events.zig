//! The observation event model: one row of poll history, the event-kind tags,
//! UTC timestamp formatting, and appending a run's events to the history log.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zstd = @import("zstd.zig");
const log = @import("context.zig").log;

/// One row of the observation history. Appended to the NDJSON log as a poll
/// finds new documents or keyword shifts, and later projected into Parquet by
/// the `export` subcommand. Field names are the NDJSON/Parquet column names.
///
/// Fields added after v1 (`tier`, `confidence`, `event_identity`,
/// `published_at`, `published_epoch_ms`, `fetch_ms`, `http_status`) default to
/// empty/zero, so logs written by older builds parse unchanged and older
/// readers ignore the extra columns.
pub const Event = struct {
    observed_at: []const u8 = "", // ISO-8601 UTC, shared by all events in a run
    epoch_ms: i64 = 0, // same instant, milliseconds since the Unix epoch
    source_id: []const u8 = "",
    source_label: []const u8 = "",
    source_kind: []const u8 = "", // SourceKind tag name
    event: []const u8 = "", // see the ev_* kinds below
    document_number: []const u8 = "",
    title: []const u8 = "",
    publication_date: []const u8 = "",
    url: []const u8 = "",
    detail: []const u8 = "", // free-form: keyword hash, byte counts, etc.

    // --- v2 additions (tiering, latency backtest, per-run metrics) ---------
    tier: u8 = 0, // 1/2/3; 0 = unset (pre-v2 rows)
    confidence: []const u8 = "", // "high" | "advisory" | ""
    event_identity: []const u8 = "", // normalized identity for cross-source dedup
    published_at: []const u8 = "", // source publication timestamp, if known
    published_epoch_ms: i64 = 0, // same instant in epoch ms (0 = unknown)
    fetch_ms: i64 = 0, // per-source fetch latency for metric rows
    http_status: i64 = 0, // HTTP status for metric rows (304 = not modified)
};

// Event kinds, kept as string literals so the log stays self-describing.
pub const ev_new_document = "new_document";
pub const ev_relevant_document = "relevant_document";
pub const ev_baseline = "baseline";
pub const ev_changed = "changed";
// v2 kinds.
pub const ev_restoration = "restoration"; // decisive tier-1 trip (model present / statement)
pub const ev_advisory = "advisory"; // lower-confidence tier-2/3 change
pub const ev_fetch = "fetch"; // per-source fetch metric (latency/status)
pub const ev_market = "market"; // recorded market state / movement
pub const ev_heartbeat = "heartbeat"; // dead-man's-switch ping result

/// Format `epoch_secs` (seconds since the Unix epoch) as an ISO-8601 UTC string
/// like "2026-06-18T14:03:09Z". Pre-1970 instants clamp to the epoch.
pub fn isoUtc(arena: Allocator, epoch_secs: i64) ![]u8 {
    const secs: u64 = if (epoch_secs < 0) 0 else @intCast(epoch_secs);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(
        arena,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            yd.year,
            md.month.numeric(),
            @as(u32, md.day_index) + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        },
    );
}

/// Parse a source publication timestamp into epoch milliseconds, for the
/// latency backtest (publication-to-detection delta). Handles the two forms our
/// sources emit: a plain date "YYYY-MM-DD" and an ISO-8601 instant
/// "YYYY-MM-DDTHH:MM:SSZ". Returns null on anything else (e.g. RFC-822 pubDate),
/// so the caller records 0 = unknown rather than a wrong value.
pub fn epochMsFromIso(s: []const u8) ?i64 {
    if (s.len < 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    if (s.len >= 19 and (s[10] == 'T' or s[10] == ' ')) {
        hh = std.fmt.parseInt(i64, s[11..13], 10) catch 0;
        mm = std.fmt.parseInt(i64, s[14..16], 10) catch 0;
        ss = std.fmt.parseInt(i64, s[17..19], 10) catch 0;
    }
    const days = daysFromCivil(year, month, day);
    const secs = days * 86400 + hh * 3600 + mm * 60 + ss;
    return secs * 1000;
}

/// Days since the Unix epoch for a proleptic-Gregorian date (Howard Hinnant's
/// algorithm). Valid for the date range this tool sees.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Write `data` to `path` atomically: stage it in a uniquely named temp file
/// in the same directory (a suffix of the target path, so the rename never
/// crosses filesystems), then rename() over the target. A crash mid-write can
/// therefore never leave a torn file — readers see the old contents or the new
/// contents, whole. Shared by the state, event-sink, and log writers.
pub fn writeFileAtomic(io: Io, arena: Allocator, path: []const u8, data: []const u8) !void {
    // The random component keeps concurrent writers from colliding on the
    // staging name (the flock serializes ours, but stay safe against strays).
    var rnd: [8]u8 = undefined;
    Io.random(io, &rnd);
    const suffix = std.mem.readInt(u64, &rnd, .little);
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ path, suffix });
    errdefer Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        var file = try Io.Dir.cwd().createFile(io, tmp_path, .{
            .permissions = .fromMode(0o600),
        });
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o600));
        try file.writeStreamingAll(io, data);
        try file.sync(io);
    }
    try Io.Dir.cwd().rename(tmp_path, .cwd(), path, io);
    try syncParentDir(io, path);
}

/// Sync the directory entry containing `path`. A file fsync before rename is
/// not sufficient to make the rename survive a power loss on all filesystems.
pub fn syncParentDir(io: Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    var dir_file = try Io.Dir.cwd().openFile(io, parent, .{ .allow_directory = true });
    defer dir_file.close(io);
    try dir_file.sync(io);
}

const LogLock = struct {
    file: Io.File,

    fn release(self: *LogLock, io: Io) void {
        self.file.close(io);
    }
};

fn acquireLogLock(io: Io, arena: Allocator, path: []const u8, mode: Io.File.Lock) !LogLock {
    const lock_path = try std.fmt.allocPrint(arena, "{s}.lock", .{path});
    const file = try Io.Dir.cwd().createFile(io, lock_path, .{
        .truncate = false,
        .lock = mode,
        .permissions = .fromMode(0o600),
    });
    errdefer file.close(io);
    try file.setPermissions(io, .fromMode(0o600));
    return .{ .file = file };
}

const Manifest = struct {
    version: u8 = 1,
    base: []const u8 = "",
    cutoff: u64 = 0,
    next: u64 = 1,
    count: ?usize = null,
};

const compact_interval: u64 = 32;
const max_log_bytes = 256 * 1024 * 1024;

fn segmentDir(arena: Allocator, log_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.segments", .{log_path});
}

fn manifestPath(arena: Allocator, log_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.manifest", .{log_path});
}

fn manifestBackupPath(arena: Allocator, log_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.manifest.backup", .{log_path});
}

fn ensureSegmentDir(io: Io, arena: Allocator, log_path: []const u8) ![]const u8 {
    const path = try segmentDir(arena, log_path);
    _ = try Io.Dir.cwd().createDirPathStatus(io, path, .fromMode(0o700));
    var dir = try Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
    return path;
}

fn validBaseName(name: []const u8) bool {
    if (name.len <= "base-.zst".len or
        !std.mem.startsWith(u8, name, "base-") or
        !std.mem.endsWith(u8, name, ".zst")) return false;
    _ = std.fmt.parseInt(u64, name[5 .. name.len - 4], 16) catch return false;
    return true;
}

fn validateManifest(manifest: Manifest) !void {
    if (manifest.version != 1 or manifest.next == 0 or manifest.cutoff >= manifest.next)
        return error.InvalidManifest;
    if (manifest.base.len > 0 and !validBaseName(manifest.base))
        return error.InvalidManifest;
    if (manifest.cutoff > 0 and manifest.base.len == 0)
        return error.InvalidManifest;
}

fn readManifestFile(io: Io, arena: Allocator, path: []const u8) !Manifest {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024));
    const DiskManifest = struct {
        version: u8,
        base: []const u8,
        cutoff: u64,
        next: u64,
        count: ?usize = null,
    };
    const disk = std.json.parseFromSliceLeaky(DiskManifest, arena, bytes, .{}) catch
        return error.InvalidManifest;
    const manifest: Manifest = .{
        .version = disk.version,
        .base = disk.base,
        .cutoff = disk.cutoff,
        .next = disk.next,
        .count = disk.count,
    };
    try validateManifest(manifest);
    return manifest;
}

const LoadedManifest = struct {
    value: Manifest,
    recovered_from_backup: bool = false,
};

fn loadManifest(io: Io, arena: Allocator, log_path: []const u8) !LoadedManifest {
    const primary_path = try manifestPath(arena, log_path);
    const primary = readManifestFile(io, arena, primary_path) catch |primary_err| {
        const backup_path = try manifestBackupPath(arena, log_path);
        const backup = readManifestFile(io, arena, backup_path) catch |backup_err| {
            if (primary_err == error.FileNotFound and backup_err == error.FileNotFound)
                return .{ .value = .{} };
            return primary_err;
        };
        return .{ .value = backup, .recovered_from_backup = true };
    };
    return .{ .value = primary };
}

fn saveManifest(io: Io, arena: Allocator, log_path: []const u8, manifest: Manifest) !void {
    try validateManifest(manifest);
    const data = try std.json.Stringify.valueAlloc(arena, manifest, .{});
    try writeFileAtomic(io, arena, try manifestPath(arena, log_path), data);
    try writeFileAtomic(io, arena, try manifestBackupPath(arena, log_path), data);
}

fn segmentName(arena: Allocator, sequence: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d:0>20}.zst", .{sequence});
}

fn parseSegmentName(name: []const u8) ?u64 {
    if (name.len != 24 or !std.mem.endsWith(u8, name, ".zst")) return null;
    return std.fmt.parseInt(u64, name[0..20], 10) catch null;
}

fn cleanupOrphans(io: Io, arena: Allocator, log_path: []const u8, manifest: Manifest) !void {
    const dir_path = try segmentDir(arena, log_path);
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var stale: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const orphan_base = std.mem.startsWith(u8, entry.name, "base-") and
            std.mem.endsWith(u8, entry.name, ".zst") and
            !std.mem.eql(u8, entry.name, manifest.base);
        if (orphan_base or std.mem.endsWith(u8, entry.name, ".tmp"))
            try stale.append(arena, try arena.dupe(u8, entry.name));
    }
    for (stale.items) |name| dir.deleteFile(io, name) catch {};
    if (stale.items.len > 0)
        try syncParentDir(io, try std.fmt.allocPrint(arena, "{s}/x", .{dir_path}));
}

/// Append one immutable, atomically committed frame. The manifest is tiny and
/// fixed-size; normal append work is therefore O(the new frame).
pub fn appendLog(io: Io, arena: Allocator, log_path: []const u8, events: []const Event, max_events: usize) !void {
    if (events.len == 0) return;

    var buf: std.ArrayList(u8) = .empty;
    for (events) |ev| {
        const line = try std.json.Stringify.valueAlloc(arena, ev, .{});
        try buf.appendSlice(arena, line);
        try buf.append(arena, '\n');
    }
    const frame = try zstd.compress(io, arena, buf.items);

    var lock = try acquireLogLock(io, arena, log_path, .exclusive);
    defer lock.release(io);
    const dir_path = try ensureSegmentDir(io, arena, log_path);
    const loaded = try loadManifest(io, arena, log_path);
    if (loaded.recovered_from_backup) return error.ManifestRecoveryRequired;
    var manifest = loaded.value;
    const sequence = manifest.next;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, try segmentName(arena, sequence) });
    if (Io.Dir.cwd().access(io, path, .{})) |_| {
        return error.UncommittedSegmentConflict;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try commitFrame(io, arena, path, frame, null);
    manifest.next = sequence + 1;
    manifest.count = if (manifest.count) |count| count +| events.len else null;
    try saveManifest(io, arena, log_path, manifest);
    log("appended {d} event(s) to {s} ({d} bytes compressed)", .{ events.len, log_path, frame.len });
    if (manifest.count == null or manifest.count.? > max_events or sequence -| manifest.cutoff >= compact_interval)
        try compactLocked(io, arena, log_path, max_events, manifest);
}

/// Stage and sync a frame before rename. `fail_after` is a test-only disk-full
/// injection point; a failure leaves at most an ignored `.tmp` file.
fn commitFrame(io: Io, arena: Allocator, path: []const u8, bytes: []const u8, fail_after: ?usize) !void {
    var rnd: [8]u8 = undefined;
    Io.random(io, &rnd);
    const tmp = try std.fmt.allocPrint(arena, "{s}.{x}.tmp", .{ path, std.mem.readInt(u64, &rnd, .little) });
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    {
        var file = try Io.Dir.cwd().createFile(io, tmp, .{
            .permissions = .fromMode(0o600),
        });
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o600));
        if (fail_after) |n| {
            try file.writeStreamingAll(io, bytes[0..@min(n, bytes.len)]);
            return error.NoSpaceLeft;
        }
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try Io.Dir.cwd().rename(tmp, .cwd(), path, io);
    try syncParentDir(io, path);
}

const Segment = struct { sequence: u64, name: []const u8 };

fn listSegments(io: Io, arena: Allocator, log_path: []const u8) ![]Segment {
    const path = try segmentDir(arena, log_path);
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var result: std.ArrayList(Segment) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const sequence = parseSegmentName(entry.name) orelse continue;
        try result.append(arena, .{ .sequence = sequence, .name = try arena.dupe(u8, entry.name) });
    }
    std.mem.sort(Segment, result.items, {}, struct {
        fn less(_: void, a: Segment, b: Segment) bool {
            return a.sequence < b.sequence;
        }
    }.less);
    return result.items;
}

fn appendDecoded(io: Io, arena: Allocator, out: *std.ArrayList(u8), path: []const u8, recover: bool) !void {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_log_bytes));
    const data = if (recover)
        try zstd.decompressRecover(io, arena, raw)
    else
        try zstd.decompress(io, arena, raw);
    try out.appendSlice(arena, data);
    if (data.len > 0 and data[data.len - 1] != '\n') try out.append(arena, '\n');
}

const ReadLogResult = struct {
    data: []u8,
    safe_to_compact: bool,
};

fn readLogLocked(io: Io, arena: Allocator, log_path: []const u8, manifest: Manifest) !ReadLogResult {
    var out: std.ArrayList(u8) = .empty;
    var found = false;
    var safe_to_compact = true;
    if (manifest.base.len > 0) {
        const base_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ try segmentDir(arena, log_path), manifest.base });
        try appendDecoded(io, arena, &out, base_path, false);
        found = true;
    } else {
        appendDecoded(io, arena, &out, log_path, false) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                appendDecoded(io, arena, &out, log_path, true) catch return err;
                found = true;
                safe_to_compact = false;
            },
        };
        if (out.items.len > 0) found = true;
    }
    const dir_path = try segmentDir(arena, log_path);
    var expected = manifest.cutoff + 1;
    for (try listSegments(io, arena, log_path)) |segment| {
        if (segment.sequence <= manifest.cutoff) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, segment.name });
        if (segment.sequence < manifest.next) {
            if (segment.sequence != expected) return error.MissingCommittedSegment;
            try appendDecoded(io, arena, &out, path, false);
            found = true;
            expected += 1;
        } else {
            var ignored: std.ArrayList(u8) = .empty;
            appendDecoded(io, arena, &ignored, path, false) catch {
                safe_to_compact = false;
                log("event log: ignoring unreadable uncommitted segment {s}", .{path});
            };
        }
    }
    if (expected != manifest.next) return error.MissingCommittedSegment;
    if (!found) return error.FileNotFound;
    return .{ .data = out.items, .safe_to_compact = safe_to_compact };
}

/// Read a consistent logical log. Corrupt legacy tails and isolated bad
/// segments do not hide earlier committed history.
///
/// Memory: this materializes the whole logical log (base generation + every
/// committed segment, each decompressed) into `arena` in one pass, so peak
/// resident bytes scale with the *retained* history, not with a fixed window.
/// That footprint is bounded, not unbounded: each on-disk component is capped
/// at `max_log_bytes`, and automatic compaction retains only the newest
/// `FABLE_MONITOR_MAX_EVENTS` rows (default 100_000). The two consumers are
/// tolerant of this: `export` is a one-shot process that exits afterward, and
/// the `serve` dashboard cache tail-caps the parse to its own small window.
/// Before raising `FABLE_MONITOR_MAX_EVENTS` substantially on a memory-
/// constrained host, size the ceiling deliberately (or teach the long-lived
/// `serve` reader to stream/page), since the whole compacted set is decompressed
/// at once under the shared log lock.
pub fn readLog(io: Io, arena: Allocator, log_path: []const u8) ![]u8 {
    var lock = try acquireLogLock(io, arena, log_path, .shared);
    defer lock.release(io);
    const loaded = try loadManifest(io, arena, log_path);
    return (try readLogLocked(io, arena, log_path, loaded.value)).data;
}

/// Restore a corrupt or missing primary manifest from its validated backup.
/// Every committed component is read successfully before the primary is
/// replaced, so recovery cannot bless a manifest that references lost data.
pub fn recoverManifest(io: Io, arena: Allocator, log_path: []const u8) !void {
    var lock = try acquireLogLock(io, arena, log_path, .exclusive);
    defer lock.release(io);
    const loaded = try loadManifest(io, arena, log_path);
    if (!loaded.recovered_from_backup) return;
    _ = try readLogLocked(io, arena, log_path, loaded.value);
    try saveManifest(io, arena, log_path, loaded.value);
}

/// A cheap cache key that changes whenever the manifest or a legacy log does.
pub fn logStamp(io: Io, arena: Allocator, log_path: []const u8) i96 {
    var latest: i96 = std.math.minInt(i96);
    for ([_][]const u8{
        log_path,
        manifestPath(arena, log_path) catch return latest,
        manifestBackupPath(arena, log_path) catch return latest,
    }) |path| {
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        latest = @max(latest, stat.mtime.nanoseconds);
    }
    return latest;
}

/// Rewrite the logical history to one generation and retain its newest rows.
pub fn compactLog(io: Io, arena: Allocator, log_path: []const u8, max_events: usize) !void {
    var lock = try acquireLogLock(io, arena, log_path, .exclusive);
    defer lock.release(io);
    const loaded = try loadManifest(io, arena, log_path);
    if (loaded.recovered_from_backup) return error.ManifestRecoveryRequired;
    try compactLocked(io, arena, log_path, max_events, loaded.value);
}

fn compactLocked(io: Io, arena: Allocator, log_path: []const u8, max_events: usize, old_manifest: Manifest) !void {
    const read_result = try readLogLocked(io, arena, log_path, old_manifest);
    if (!read_result.safe_to_compact) return error.UnsafeToCompact;
    const data = read_result.data;
    var rows: std.ArrayList(Event) = .empty;
    var split = std.mem.splitScalar(u8, data, '\n');
    while (split.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const event = std.json.parseFromSliceLeaky(Event, arena, trimmed, .{ .ignore_unknown_fields = true }) catch
            return error.InvalidEventLog;
        try rows.append(arena, event);
    }
    std.mem.sort(Event, rows.items, {}, struct {
        fn less(_: void, a: Event, b: Event) bool {
            return a.epoch_ms < b.epoch_ms;
        }
    }.less);
    const start = rows.items.len -| max_events;
    var retained: std.ArrayList(u8) = .empty;
    for (rows.items[start..]) |event| {
        try retained.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, event, .{}));
        try retained.append(arena, '\n');
    }
    const compressed = try zstd.compress(io, arena, retained.items);
    const dir_path = try ensureSegmentDir(io, arena, log_path);
    var rnd: [8]u8 = undefined;
    Io.random(io, &rnd);
    const base_name = try std.fmt.allocPrint(arena, "base-{x}.zst", .{std.mem.readInt(u64, &rnd, .little)});
    try commitFrame(io, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, base_name }), compressed, null);
    const segments = try listSegments(io, arena, log_path);
    const cutoff = old_manifest.next - 1;
    const new_manifest: Manifest = .{
        .base = base_name,
        .cutoff = cutoff,
        .next = old_manifest.next,
        .count = rows.items.len - start,
    };
    try saveManifest(io, arena, log_path, new_manifest);

    for (segments) |segment| if (segment.sequence <= cutoff)
        Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, segment.name })) catch {};
    if (old_manifest.base.len > 0 and !std.mem.eql(u8, old_manifest.base, base_name))
        Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, old_manifest.base })) catch {};
    if (old_manifest.base.len == 0) {
        Io.Dir.cwd().deleteFile(io, log_path) catch {};
        try syncParentDir(io, log_path);
    }
    try cleanupOrphans(io, arena, log_path, new_manifest);
    try syncParentDir(io, try std.fmt.allocPrint(arena, "{s}/x", .{dir_path}));
    log("compacted {s}: retained {d} of {d} event(s)", .{ log_path, rows.items.len - start, rows.items.len });
}

const testing = std.testing;

test "concatenated zstd frames decompress as one stream (appendLog's format)" {
    // appendLog writes one independent frame per run; `zstd -d` (which
    // zstd.decompress shells to) must decode the concatenation as one stream.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;

    const f1 = try zstd.compress(io, a, "{\"event\":\"one\"}\n");
    const f2 = try zstd.compress(io, a, "{\"event\":\"two\"}\n");
    const cat = try std.mem.concat(a, u8, &.{ f1, f2 });
    const out = try zstd.decompress(io, a, cat);
    try testing.expectEqualStrings("{\"event\":\"one\"}\n{\"event\":\"two\"}\n", out);
}

test "writeFileAtomic creates and then replaces the target whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;

    const path = ".test-fable-monitor-atomic.tmp-target";
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeFileAtomic(io, a, path, "first contents");
    try writeFileAtomic(io, a, path, "second");
    const got = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    try testing.expectEqualStrings("second", got);
}

fn cleanupTestLog(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
    const a = testing.allocator;
    const lock_path = std.fmt.allocPrint(a, "{s}.lock", .{path}) catch return;
    defer a.free(lock_path);
    Io.Dir.cwd().deleteFile(io, lock_path) catch {};
    const manifest_path = std.fmt.allocPrint(a, "{s}.manifest", .{path}) catch return;
    defer a.free(manifest_path);
    Io.Dir.cwd().deleteFile(io, manifest_path) catch {};
    Io.Dir.cwd().deleteTree(io, manifest_path) catch {};
    const backup_path = std.fmt.allocPrint(a, "{s}.manifest.backup", .{path}) catch return;
    defer a.free(backup_path);
    Io.Dir.cwd().deleteFile(io, backup_path) catch {};
    Io.Dir.cwd().deleteTree(io, backup_path) catch {};
    const dir_path = std.fmt.allocPrint(a, "{s}.segments", .{path}) catch return;
    defer a.free(dir_path);
    Io.Dir.cwd().deleteTree(io, dir_path) catch {};
}

test "segmented append and compaction retain the newest events" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-append-log.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const first = [_]Event{.{ .epoch_ms = 1, .event = "one" }};
    const second = [_]Event{.{ .epoch_ms = 2, .event = "two" }};
    try appendLog(io, a, path, &first, 100);
    try appendLog(io, a, path, &second, 100);

    const decoded = try readLog(io, a, path);
    try testing.expect(std.mem.indexOf(u8, decoded, "\"event\":\"one\"") != null);
    try testing.expect(std.mem.indexOf(u8, decoded, "\"event\":\"two\"") != null);

    try compactLog(io, a, path, 1);
    const compacted = try readLog(io, a, path);
    try testing.expect(std.mem.indexOf(u8, compacted, "\"event\":\"one\"") == null);
    try testing.expect(std.mem.indexOf(u8, compacted, "\"event\":\"two\"") != null);
}

test "automatic retention compacts an oversized append" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-auto-retain.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const batch = [_]Event{
        .{ .epoch_ms = 1, .event = "one" },
        .{ .epoch_ms = 2, .event = "two" },
        .{ .epoch_ms = 3, .event = "three" },
    };
    try appendLog(io, a, path, &batch, 2);
    const data = try readLog(io, a, path);
    try testing.expect(std.mem.indexOf(u8, data, "\"event\":\"one\"") == null);
    try testing.expect(std.mem.indexOf(u8, data, "\"event\":\"two\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"event\":\"three\"") != null);
}

test "disk-full during frame staging leaves committed history readable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-disk-full.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const first = [_]Event{.{ .event = "committed" }};
    try appendLog(io, a, path, &first, 100);
    const dir_path = try ensureSegmentDir(io, a, path);
    const failed_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, try segmentName(a, 2) });
    const frame = try zstd.compress(io, a, "{\"event\":\"torn\"}\n");
    try testing.expectError(error.NoSpaceLeft, commitFrame(io, a, failed_path, frame, frame.len / 2));
    const data = try readLog(io, a, path);
    try testing.expect(std.mem.indexOf(u8, data, "committed") != null);
    try testing.expect(std.mem.indexOf(u8, data, "torn") == null);
}

test "legacy torn append and bad segment do not reject valid history" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-torn-legacy.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const good = try zstd.compress(io, a, "{\"event\":\"good\"}\n");
    const torn = try zstd.compress(io, a, "{\"event\":\"lost\"}\n");
    const legacy = try std.mem.concat(a, u8, &.{ good, torn[0 .. torn.len / 2] });
    try writeFileAtomic(io, a, path, legacy);
    const dir_path = try ensureSegmentDir(io, a, path);
    try writeFileAtomic(io, a, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, try segmentName(a, 1) }), "not zstd");
    const data = try readLog(io, a, path);
    try testing.expect(std.mem.indexOf(u8, data, "good") != null);
    try testing.expect(std.mem.indexOf(u8, data, "lost") == null);
}

test "malformed manifest fails closed instead of becoming empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-bad-manifest.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const legacy = try zstd.compress(io, a, "{\"event\":\"legacy\"}\n");
    try writeFileAtomic(io, a, path, legacy);
    try writeFileAtomic(io, a, try manifestPath(a, path), "{}");

    try testing.expectError(error.InvalidManifest, readLog(io, a, path));
    const event = [_]Event{.{ .event = "must-not-append" }};
    try testing.expectError(error.InvalidManifest, appendLog(io, a, path, &event, 100));
    const retained = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    try testing.expectEqualSlices(u8, legacy, retained);
}

test "validated manifest backup recovers reads but mutations stay closed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-manifest-backup.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const event = [_]Event{.{ .event = "committed" }};
    try appendLog(io, a, path, &event, 100);
    const primary_path = try manifestPath(a, path);
    const backup_path = try manifestBackupPath(a, path);
    const primary = try Io.Dir.cwd().readFileAlloc(io, primary_path, a, .limited(4096));
    const backup = try Io.Dir.cwd().readFileAlloc(io, backup_path, a, .limited(4096));
    try testing.expectEqualSlices(u8, primary, backup);

    try writeFileAtomic(io, a, primary_path, "{broken");
    const recovered = try readLog(io, a, path);
    try testing.expect(std.mem.indexOf(u8, recovered, "committed") != null);
    try testing.expectError(error.ManifestRecoveryRequired, appendLog(io, a, path, &event, 100));
    try testing.expectError(error.ManifestRecoveryRequired, compactLog(io, a, path, 100));

    try recoverManifest(io, a, path);
    const restored_primary = try Io.Dir.cwd().readFileAlloc(io, primary_path, a, .limited(4096));
    try testing.expectEqualSlices(u8, backup, restored_primary);
    try appendLog(io, a, path, &event, 100);
}

test "manifest read failure does not fall back to an empty generation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-manifest-io.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const legacy = try zstd.compress(io, a, "{\"event\":\"legacy\"}\n");
    try writeFileAtomic(io, a, path, legacy);
    try Io.Dir.cwd().createDir(io, try manifestPath(a, path), .default_dir);

    try testing.expectError(error.IsDir, readLog(io, a, path));
    const event = [_]Event{.{ .event = "must-not-append" }};
    try testing.expectError(error.IsDir, appendLog(io, a, path, &event, 100));
    const retained = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    try testing.expectEqualSlices(u8, legacy, retained);
}

test "committed segment corruption surfaces and compaction deletes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-committed-corruption.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const first = [_]Event{.{ .event = "base" }};
    try appendLog(io, a, path, &first, 100);
    try compactLog(io, a, path, 100);
    const loaded = try loadManifest(io, a, path);
    const dir_path = try segmentDir(a, path);
    const base_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, loaded.value.base });

    const second = [_]Event{.{ .event = "segment" }};
    try appendLog(io, a, path, &second, 100);
    const committed_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, try segmentName(a, loaded.value.next) });
    try writeFileAtomic(io, a, committed_path, "not zstd");
    const orphan_path = try std.fmt.allocPrint(a, "{s}/base-orphan.zst", .{dir_path});
    try writeFileAtomic(io, a, orphan_path, "orphan");

    try testing.expectError(error.ZstdFailed, readLog(io, a, path));
    try testing.expectError(error.ZstdFailed, compactLog(io, a, path, 100));
    try Io.Dir.cwd().access(io, base_path, .{});
    try Io.Dir.cwd().access(io, committed_path, .{});
    try Io.Dir.cwd().access(io, orphan_path, .{});
}

test "unreadable uncommitted segment is tolerated but blocks deletion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-uncommitted-corruption.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const event = [_]Event{.{ .event = "kept" }};
    try appendLog(io, a, path, &event, 100);
    try compactLog(io, a, path, 100);
    const loaded = try loadManifest(io, a, path);
    const dir_path = try segmentDir(a, path);
    const base_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, loaded.value.base });
    const stray_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, try segmentName(a, loaded.value.next) });
    try writeFileAtomic(io, a, stray_path, "not zstd");

    const recovered = try readLog(io, a, path);
    try testing.expect(std.mem.indexOf(u8, recovered, "kept") != null);
    try testing.expectError(error.UnsafeToCompact, compactLog(io, a, path, 100));
    try Io.Dir.cwd().access(io, base_path, .{});
    try Io.Dir.cwd().access(io, stray_path, .{});
}

test "committed component read failure surfaces without deleting the base" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    const path = ".test-fable-monitor-component-io.zst";
    defer cleanupTestLog(io, path);
    cleanupTestLog(io, path);

    const event = [_]Event{.{ .event = "kept" }};
    try appendLog(io, a, path, &event, 100);
    try compactLog(io, a, path, 100);
    const loaded = try loadManifest(io, a, path);
    const base_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ try segmentDir(a, path), loaded.value.base });
    try Io.Dir.cwd().deleteFile(io, base_path);
    try Io.Dir.cwd().createDir(io, base_path, .default_dir);

    try testing.expectError(error.IsDir, readLog(io, a, path));
    try testing.expectError(error.IsDir, compactLog(io, a, path, 100));
    var dir = try Io.Dir.cwd().openDir(io, base_path, .{});
    dir.close(io);
}

test "epochMsFromIso parses dates and instants, round-trips through isoUtc" {
    // 1970-01-01 is epoch 0.
    try testing.expectEqual(@as(i64, 0), epochMsFromIso("1970-01-01").?);
    // A known instant: 2026-06-28T00:00:00Z.
    const ms = epochMsFromIso("2026-06-28T12:34:56Z").?;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const iso = try isoUtc(arena_state.allocator(), @divFloor(ms, 1000));
    try testing.expectEqualStrings("2026-06-28T12:34:56Z", iso);
    // Plain date floors to midnight UTC.
    const day = epochMsFromIso("2026-06-28").?;
    const iso_day = try isoUtc(arena_state.allocator(), @divFloor(day, 1000));
    try testing.expectEqualStrings("2026-06-28T00:00:00Z", iso_day);
    // Unparseable forms return null.
    try testing.expect(epochMsFromIso("Mon, 01 Jan 2026 00:00:00 GMT") == null);
    try testing.expect(epochMsFromIso("") == null);
}
