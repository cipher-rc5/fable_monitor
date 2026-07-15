//! The shared per-run `Context` and the `log` helper. Kept in its own module so
//! the concern modules (fetch, state, events, export) can share `Context`
//! without forming an import cycle: this module depends only on `events.zig`
//! for the `Event` type, and never imports those concern modules back.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Event = @import("events.zig").Event;

/// Per-run state threaded through the poll. Holds the I/O handle, the arena all
/// per-run allocations come from, resolved file paths, and the observations
/// accumulated this run.
pub const Context = struct {
    io: Io,
    arena: Allocator,
    state_path: []const u8,
    log_path: []const u8,
    notify_cmd: ?[]const u8,
    observed_at: []const u8,
    epoch_ms: i64,
    events: std.ArrayList(Event) = .empty,
    changed: bool = false,

    /// Optional caller-supplied correlation ID. Existing callers may leave this
    /// empty; `telemetry` then uses the run timestamp as the correlation value.
    run_id: []const u8 = "",

    /// Record an observation, stamping it with this run's poll time.
    pub fn record(self: *Context, e: Event) !void {
        var ev = e;
        ev.observed_at = self.observed_at;
        ev.epoch_ms = self.epoch_ms;
        try self.events.append(self.arena, ev);
    }

    /// Emit one machine-readable diagnostic without changing the legacy logger.
    pub fn telemetry(self: *const Context, level: LogLevel, event: []const u8, source: []const u8, err: []const u8, message: []const u8) void {
        logJson(.{
            .level = level,
            .event = event,
            .run = if (self.run_id.len > 0) self.run_id else self.observed_at,
            .source = source,
            .@"error" = err,
            .message = message,
        });
    }
};

pub const LogLevel = enum { debug, info, warn, err };

/// Stable envelope for JSON diagnostics. Correlation fields are always present;
/// use an empty string when a field does not apply rather than changing shape.
pub const JsonLog = struct {
    level: LogLevel,
    event: []const u8,
    run: []const u8,
    source: []const u8,
    @"error": []const u8,
    message: []const u8 = "",
};

/// Emit a line to stderr, prefixed for easy grepping in launchd/cron logs.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[fable-monitor] " ++ fmt ++ "\n", args);
}

/// Write a single JSON object to stderr. Allocation or encoding failure falls
/// back to the established text format, so telemetry cannot hide diagnostics.
pub fn logJson(entry: JsonLog) void {
    const allocator = std.heap.page_allocator;
    const encoded = std.json.Stringify.valueAlloc(allocator, entry, .{}) catch {
        log("telemetry_encode_failed event={s} source={s} error={s}", .{ entry.event, entry.source, entry.@"error" });
        return;
    };
    defer allocator.free(encoded);
    std.debug.print("{s}\n", .{encoded});
}

test "JSON log envelope has stable correlation fields and escapes values" {
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, JsonLog{
        .level = .err,
        .event = "fetch_failed",
        .run = "run-1",
        .source = "source\"one",
        .@"error" = "Timeout",
        .message = "request failed",
    }, .{});
    defer std.testing.allocator.free(encoded);

    const parsed = try std.json.parseFromSlice(JsonLog, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(LogLevel.err, parsed.value.level);
    try std.testing.expectEqualStrings("fetch_failed", parsed.value.event);
    try std.testing.expectEqualStrings("run-1", parsed.value.run);
    try std.testing.expectEqualStrings("source\"one", parsed.value.source);
    try std.testing.expectEqualStrings("Timeout", parsed.value.@"error");
}
