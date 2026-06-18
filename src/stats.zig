//! Opt-in resource self-report. When `FABLE_MONITOR_STATS=1` is set, the program
//! logs its peak memory and CPU at the end of a run — separately for this
//! process and for the child processes it spawned (`curl`, `zstd`). The child
//! figure is the useful one external tools miss: `/usr/bin/time -l` on the
//! parent does not account for grandchildren.
//!
//! Implementation is `getrusage(2)`, which is essentially free, so the report
//! adds nothing measurable to a run. It is purely diagnostic (stderr).

const std = @import("std");
const builtin = @import("builtin");
const log = @import("context.zig").log;

const rusage = std.posix.rusage;

/// Log a one-line peak-RSS + CPU summary for this process and its children.
pub fn report() void {
    const self = std.posix.getrusage(rusage.SELF);
    const kids = std.posix.getrusage(rusage.CHILDREN);
    log(
        "stats: process peak RSS {d:.1} MiB, CPU {d:.3}s · children (curl/zstd) peak RSS {d:.1} MiB, CPU {d:.3}s",
        .{ mib(self.maxrss), cpuSecs(self), mib(kids.maxrss), cpuSecs(kids) },
    );
}

/// `maxrss` is bytes on Darwin/BSD but kibibytes on Linux; normalize to MiB.
fn mib(maxrss: isize) f64 {
    const bytes: f64 = @floatFromInt(maxrss);
    const normalized = if (builtin.os.tag == .linux) bytes * 1024.0 else bytes;
    return normalized / (1024.0 * 1024.0);
}

fn cpuSecs(ru: rusage) f64 {
    return seconds(ru.utime) + seconds(ru.stime);
}

fn seconds(t: std.posix.timeval) f64 {
    return @as(f64, @floatFromInt(t.sec)) + @as(f64, @floatFromInt(t.usec)) / 1_000_000.0;
}

test "mib converts the platform's maxrss unit to MiB" {
    // Darwin reports bytes: 2 MiB worth of bytes → 2.0.
    if (builtin.os.tag != .linux) {
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), mib(2 * 1024 * 1024), 1e-9);
    }
}

test "seconds folds a timeval into fractional seconds" {
    const t: std.posix.timeval = .{ .sec = 1, .usec = 500_000 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), seconds(t), 1e-9);
}
