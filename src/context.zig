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

    /// Record an observation, stamping it with this run's poll time.
    pub fn record(self: *Context, e: Event) !void {
        var ev = e;
        ev.observed_at = self.observed_at;
        ev.epoch_ms = self.epoch_ms;
        try self.events.append(self.arena, ev);
    }
};

/// Emit a line to stderr, prefixed for easy grepping in launchd/cron logs.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[fable-monitor] " ++ fmt ++ "\n", args);
}
