//! zstd compression, delegated to the system `zstd` binary (see
//! docs/design-decisions.md). Zig's std ships only a zstd *decompressor*, so all
//! compression — and, for one code path, decompression — goes through the
//! binary, mirroring the curl decision.
//!
//! These helpers take primitives (`io`, `arena`) rather than the whole
//! `Context` so the module stays free of any dependency on the CLI types.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parquet = @import("parquet.zig");
const log = @import("context.zig").log;

const zstd_tmp = ".fable-monitor.zstd.ztmp";

/// Run the `zstd` binary over `input`, returning its stdout. `flags` precede
/// the temp input file. `std.process.run` cannot feed a child's stdin, so the
/// input is staged in a temp file — which also sidesteps any pipe-buffer
/// deadlock, since zstd reads a file while we drain its stdout. Runs are
/// single-threaded (one poll at a time), so a fixed temp name is safe; it is
/// removed afterward.
fn zstdFilter(io: Io, arena: Allocator, flags: []const []const u8, input: []const u8) ![]u8 {
    const dir = Io.Dir.cwd();
    {
        var f = try dir.createFile(io, zstd_tmp, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, input);
    }
    defer dir.deleteFile(io, zstd_tmp) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "zstd");
    for (flags) |fl| try argv.append(arena, fl);
    try argv.append(arena, "--");
    try argv.append(arena, zstd_tmp);

    const result = try std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(256 * 1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            log("zstd exit {d}: {s}", .{ code, std.mem.trim(u8, result.stderr, " \n\r") });
            return error.ZstdFailed;
        },
        else => return error.ZstdFailed,
    }
    return result.stdout;
}

/// Compress `data` with the system `zstd` binary.
pub fn compress(io: Io, arena: Allocator, data: []const u8) ![]u8 {
    return zstdFilter(io, arena, &.{ "-q", "-c" }, data);
}

/// Decompress `data` with the system `zstd` binary.
pub fn decompress(io: Io, arena: Allocator, data: []const u8) ![]u8 {
    return zstdFilter(io, arena, &.{ "-q", "-d", "-c" }, data);
}

/// Backing context for the `parquet.Compressor` thunk: the bits `compress`
/// needs to run a page through `zstd`.
pub const CompressorCtx = struct {
    io: Io,
    arena: Allocator,
};

/// `parquet.Compressor` thunk: compress one Parquet page with zstd.
fn compressThunk(context: *anyopaque, data: []const u8) anyerror![]const u8 {
    const cc: *CompressorCtx = @ptrCast(@alignCast(context));
    return compress(cc.io, cc.arena, data);
}

/// Build a `parquet.Compressor` backed by the system `zstd` binary. `cc` must
/// outlive the returned compressor (callers keep it on the stack across the
/// `writeTable` call).
pub fn compressor(cc: *CompressorCtx) parquet.Compressor {
    return .{ .context = @ptrCast(cc), .func = compressThunk };
}
