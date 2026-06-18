//! HTTP fetching, delegated to the system `curl` binary (ubiquitous, handles
//! TLS), plus a small probe for whether a required tool is on PATH.

const std = @import("std");
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;

const version = @import("build_options").version;
const user_agent = std.fmt.comptimePrint("fable-monitor/{s}", .{version});
const ua_header = std.fmt.comptimePrint("User-Agent: {s}", .{user_agent});
const fetch_timeout_s = "30";

/// Fetch a URL with the system curl binary. Returns the response body (arena owned).
pub fn httpGet(ctx: *Context, url: []const u8) ![]u8 {
    const argv = [_][]const u8{
        "curl",                                "-sS",           "-L",
        "--max-time",                          fetch_timeout_s, "--fail",
        "-H",                                  ua_header,       "-H",
        "Accept: application/json, text/html", url,
    };
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &argv,
        .stdout_limit = .limited(16 * 1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                log("curl exit {d} for {s}: {s}", .{ code, url, std.mem.trim(u8, result.stderr, " \n\r") });
                return error.FetchFailed;
            }
        },
        else => return error.FetchFailed,
    }
    return result.stdout;
}

/// Verify a system binary can be spawned. Returns true only if
/// `<name> --version` runs and exits 0.
pub fn toolAvailable(ctx: *Context, name: []const u8) bool {
    const argv = [_][]const u8{ name, "--version" };
    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
    }) catch return false;
    switch (result.term) {
        .exited => |code| return code == 0,
        else => return false,
    }
}
