//! HTTP via the system `curl` binary (ubiquitous, handles TLS). Adds conditional
//! requests (ETag / If-Modified-Since) so high-frequency polling stays cheap and
//! polite, 429/Retry-After backoff, and small POST/ping helpers for the webhook
//! emitter and the dead-man's-switch heartbeat. Also a probe for whether a
//! required tool is on PATH.

const std = @import("std");
const Io = std.Io;
const context = @import("context.zig");
const Context = context.Context;
const log = context.log;

const version = @import("build_options").version;
const user_agent = std.fmt.comptimePrint("fable-monitor/{s} (+https://github.com/cipher-rc5/fable_monitor; export-control availability monitor)", .{version});
const ua_header = std.fmt.comptimePrint("User-Agent: {s}", .{user_agent});
const fetch_timeout_s = "30";
const post_timeout_s = "10";
/// Cap on the Retry-After honored inline, so a fast poller never blocks long.
const max_backoff_ms: u64 = 5_000;

/// A conditional-fetch outcome. On a 304 the body is empty and `not_modified`
/// is set; the cached content is unchanged. `etag`/`last_modified` are the
/// validators to persist for next time (empty if the server sent none).
pub const Response = struct {
    status: u32 = 0,
    body: []u8 = &.{},
    etag: []const u8 = "",
    last_modified: []const u8 = "",
    retry_after: []const u8 = "",
    not_modified: bool = false,
    fetch_ms: i64 = 0,
};

/// A cwd-relative temp-file name unique to this invocation (random suffix),
/// so concurrent monitor processes sharing a working directory can never
/// clobber each other's staging files.
fn tmpName(io: Io, arena: std.mem.Allocator, comptime kind: []const u8) ![]u8 {
    var buf: [8]u8 = undefined;
    io.random(&buf);
    return std.fmt.allocPrint(arena, ".fable-monitor." ++ kind ++ ".{x}.ztmp", .{std.mem.readInt(u64, &buf, .little)});
}

/// Fetch `url`, sending conditional-request headers when `etag`/`last_modified`
/// are non-empty. A 304 returns quickly with `not_modified = true` and no body.
/// 429 is retried once after a (capped) Retry-After backoff. The response's
/// fetch latency is measured and returned for the per-run metrics.
pub fn fetchConditional(
    ctx: *Context,
    url: []const u8,
    etag: []const u8,
    last_modified: []const u8,
    api_key: ?[]const u8,
) !Response {
    const start = Io.Timestamp.now(ctx.io, .real).toMilliseconds();
    var resp = try curlOnce(ctx, url, etag, last_modified, api_key);

    // Honor 429 once, then give up for this poll (the next tick retries).
    if (resp.status == 429) {
        const wait_ms = @min(max_backoff_ms, parseRetryAfterMs(resp.retry_after) orelse 1000);
        log("source fetch got 429 for {s}; backing off {d}ms then retrying once", .{ url, wait_ms });
        Io.sleep(ctx.io, Io.Duration.fromMilliseconds(@intCast(wait_ms)), .awake) catch {};
        resp = try curlOnce(ctx, url, etag, last_modified, api_key);
    }

    resp.fetch_ms = Io.Timestamp.now(ctx.io, .real).toMilliseconds() - start;
    if (resp.status >= 400) {
        log("source fetch HTTP {d} for {s}", .{ resp.status, url });
        return error.FetchFailed;
    }
    return resp;
}

/// One curl invocation. Body is captured on stdout; response headers are dumped
/// to a per-invocation temp file and parsed for status, ETag, Last-Modified,
/// and Retry-After. When `api_key` is non-empty, the Anthropic auth headers
/// are added (used only by the `api_probe` source kind); the key value is
/// staged in a 0600 temp file read via curl's `-H @file` form, so it never
/// appears in the process argument list (visible via ps) and is never logged.
/// All other callers pass null and get a byte-for-byte identical argv.
fn curlOnce(ctx: *Context, url: []const u8, etag: []const u8, last_modified: []const u8, api_key: ?[]const u8) !Response {
    const a = ctx.arena;
    const hdr_path = try tmpName(ctx.io, a, "hdr");
    defer Io.Dir.cwd().deleteFile(ctx.io, hdr_path) catch {};
    var key_path: ?[]const u8 = null;
    defer if (key_path) |p| Io.Dir.cwd().deleteFile(ctx.io, p) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{
        "curl",       "-sS",                                                            "-L",
        "--max-time", fetch_timeout_s,                                                  "-D",
        hdr_path,     "-H",                                                             ua_header,
        "-H",         "Accept: application/json, text/html, application/xml, text/xml",
    });
    if (etag.len > 0) {
        try argv.append(a, "-H");
        try argv.append(a, try std.fmt.allocPrint(a, "If-None-Match: {s}", .{etag}));
    }
    if (last_modified.len > 0) {
        try argv.append(a, "-H");
        try argv.append(a, try std.fmt.allocPrint(a, "If-Modified-Since: {s}", .{last_modified}));
    }
    // Anthropic API auth (api_probe only). The header line lives in a 0600
    // temp file that curl reads via `-H @file`, keeping the key out of argv,
    // the URL, and any log line.
    if (api_key) |key| {
        if (key.len > 0) {
            const p = try tmpName(ctx.io, a, "key");
            {
                var f = try Io.Dir.cwd().createFile(ctx.io, p, .{ .permissions = .fromMode(0o600) });
                defer f.close(ctx.io);
                try f.writeStreamingAll(ctx.io, try std.fmt.allocPrint(a, "x-api-key: {s}", .{key}));
            }
            key_path = p;
            try argv.append(a, "-H");
            try argv.append(a, try std.fmt.allocPrint(a, "@{s}", .{p}));
            try argv.append(a, "-H");
            try argv.append(a, "anthropic-version: 2023-06-01");
        }
    }
    try argv.append(a, url);

    const result = try std.process.run(a, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(16 * 1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            log("curl exit {d} for {s}: {s}", .{ code, url, std.mem.trim(u8, result.stderr, " \n\r") });
            return error.FetchFailed;
        },
        else => return error.FetchFailed,
    }

    const headers = Io.Dir.cwd().readFileAlloc(ctx.io, hdr_path, a, .limited(1024 * 1024)) catch "";
    var resp = parseHeaders(headers);
    resp.body = result.stdout;
    if (resp.status == 304) {
        resp.not_modified = true;
        resp.body = &.{};
    }
    return resp;
}

/// Parse a curl header dump: take the final HTTP status line (after any
/// redirects) and the last ETag / Last-Modified / Retry-After seen.
fn parseHeaders(headers: []const u8) Response {
    var resp = Response{};
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (std.ascii.startsWithIgnoreCase(line, "HTTP/")) {
            // "HTTP/2 304" or "HTTP/1.1 200 OK"
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            _ = it.next(); // protocol
            if (it.next()) |code| resp.status = std.fmt.parseInt(u32, code, 10) catch resp.status;
        } else if (headerValue(line, "etag:")) |v| {
            resp.etag = v;
        } else if (headerValue(line, "last-modified:")) |v| {
            resp.last_modified = v;
        } else if (headerValue(line, "retry-after:")) |v| {
            resp.retry_after = v;
        }
    }
    return resp;
}

fn headerValue(line: []const u8, name_lower: []const u8) ?[]const u8 {
    if (line.len < name_lower.len) return null;
    if (!std.ascii.eqlIgnoreCase(line[0..name_lower.len], name_lower)) return null;
    return std.mem.trim(u8, line[name_lower.len..], " \t");
}

/// Best-effort Retry-After parse: only the integer-seconds form (the HTTP-date
/// form is rare here and the fixed fallback is fine for a fast poller).
fn parseRetryAfterMs(retry_after: []const u8) ?u64 {
    const secs = std.fmt.parseInt(u64, std.mem.trim(u8, retry_after, " \t"), 10) catch return null;
    return std.math.mul(u64, secs, 1000) catch null;
}

/// Fetch a URL unconditionally, returning the body. Errors on any non-2xx.
/// Retained for callers that do not track validators.
pub fn httpGet(ctx: *Context, url: []const u8) ![]u8 {
    const resp = try fetchConditional(ctx, url, "", "", null);
    return resp.body;
}

/// A realistic desktop-Chrome identity. The honest `fable-monitor/…` UA is right
/// for the high-frequency poller, but several government sources
/// (federalregister.gov, ecfr.gov) serve a "Request Access" CAPTCHA wall to any
/// non-browser UA. The reader is a user-initiated, on-demand fetch that mirrors
/// exactly what the user's own browser would load, so it presents a browser UA
/// and browser-like Accept headers to get the real article HTML.
const browser_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

/// One-shot GET with a browser identity, following redirects. Used by the reader
/// proxy. Returns the body on any 2xx; errors otherwise. No conditional headers
/// or validators — the reader has its own TTL cache.
pub fn httpGetBrowser(ctx: *Context, url: []const u8) ![]u8 {
    const a = ctx.arena;
    const argv = [_][]const u8{
        "curl",                 "-sS",
        "-L",                   "--max-time",
        fetch_timeout_s,        "-A",
        browser_ua,             "-H",
        "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "-H",                   "Accept-Language: en-US,en;q=0.9",
        url,
    };
    const result = try std.process.run(a, ctx.io, .{
        .argv = &argv,
        .stdout_limit = .limited(16 * 1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            log("reader curl exit {d} for {s}: {s}", .{ code, url, std.mem.trim(u8, result.stderr, " \n\r") });
            return error.FetchFailed;
        },
        else => return error.FetchFailed,
    }
    return result.stdout;
}

/// POST a JSON payload to `url` (the structured-event webhook). Best-effort:
/// logs and swallows failure so a webhook outage never fails a poll. The body
/// is staged in a temp file because `std.process.run` cannot feed child stdin.
pub fn postJson(ctx: *Context, url: []const u8, json: []const u8) void {
    const a = ctx.arena;
    const tmp = tmpName(ctx.io, a, "post") catch return;
    {
        var f = Io.Dir.cwd().createFile(ctx.io, tmp, .{}) catch |err| {
            log("webhook: could not stage payload: {s}", .{@errorName(err)});
            return;
        };
        defer f.close(ctx.io);
        f.writeStreamingAll(ctx.io, json) catch return;
    }
    defer Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};

    const data_arg = std.fmt.allocPrint(a, "@{s}", .{tmp}) catch return;
    const argv = [_][]const u8{
        "curl",         "-sS",                            "--max-time",
        post_timeout_s, "-X",                             "POST",
        "-H",           "Content-Type: application/json", "-H",
        ua_header,      "--data-binary",                  data_arg,
        url,
    };
    const result = std.process.run(a, ctx.io, .{ .argv = &argv, .stdout_limit = .limited(64 * 1024) }) catch |err| {
        log("webhook POST failed: {s}", .{@errorName(err)});
        return;
    };
    switch (result.term) {
        .exited => |code| if (code != 0) log("webhook POST curl exit {d} for {s}", .{ code, url }),
        else => log("webhook POST did not exit cleanly for {s}", .{url}),
    }
}

/// Ping the dead-man's-switch heartbeat URL (healthchecks.io-style). Best-effort
/// GET; success means the monitor reported itself alive this run.
pub fn pingHeartbeat(ctx: *Context, url: []const u8) bool {
    const argv = [_][]const u8{ "curl", "-sS", "--max-time", post_timeout_s, "-o", "/dev/null", "-H", ua_header, url };
    const result = std.process.run(ctx.arena, ctx.io, .{ .argv = &argv, .stdout_limit = .limited(64 * 1024) }) catch |err| {
        log("heartbeat ping failed: {s}", .{@errorName(err)});
        return false;
    };
    switch (result.term) {
        .exited => |code| return code == 0,
        else => return false,
    }
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

const testing = std.testing;

test "parseHeaders takes the final status and last validators" {
    const dump =
        "HTTP/1.1 301 Moved Permanently\r\n" ++
        "Location: https://example.com/final\r\n" ++
        "\r\n" ++
        "HTTP/2 200\r\n" ++
        "ETag: \"abc123\"\r\n" ++
        "Last-Modified: Mon, 01 Jan 2026 00:00:00 GMT\r\n" ++
        "\r\n";
    const r = parseHeaders(dump);
    try testing.expectEqual(@as(u32, 200), r.status);
    try testing.expectEqualStrings("\"abc123\"", r.etag);
    try testing.expectEqualStrings("Mon, 01 Jan 2026 00:00:00 GMT", r.last_modified);
}

test "parseHeaders recognizes a 304" {
    const r = parseHeaders("HTTP/2 304\r\n\r\n");
    try testing.expectEqual(@as(u32, 304), r.status);
}

test "parseHeaders captures Retry-After" {
    const r = parseHeaders("HTTP/2 429\r\nRetry-After: 120\r\n\r\n");
    try testing.expectEqual(@as(u32, 429), r.status);
    try testing.expectEqualStrings("120", r.retry_after);
}

test "parseRetryAfterMs handles the integer-seconds form only" {
    try testing.expectEqual(@as(?u64, 120_000), parseRetryAfterMs("120"));
    try testing.expectEqual(@as(?u64, 0), parseRetryAfterMs("0"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs(""));
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs("Fri, 31 Dec 2027 23:59:59 GMT"));
    // Overflow of the seconds-to-ms conversion must not wrap.
    try testing.expectEqual(@as(?u64, null), parseRetryAfterMs("18446744073709551615"));
}

test "tmpName is unique per invocation" {
    const a = testing.allocator;
    const one = try tmpName(testing.io, a, "hdr");
    defer a.free(one);
    const two = try tmpName(testing.io, a, "hdr");
    defer a.free(two);
    try testing.expect(!std.mem.eql(u8, one, two));
    try testing.expect(std.mem.startsWith(u8, one, ".fable-monitor.hdr."));
    try testing.expect(std.mem.endsWith(u8, one, ".ztmp"));
}

test "headerValue is case-insensitive on the name" {
    try testing.expectEqualStrings("\"x\"", headerValue("etag: \"x\"", "etag:").?);
    try testing.expectEqualStrings("\"x\"", headerValue("ETag: \"x\"", "etag:").?);
    try testing.expect(headerValue("Server: nginx", "etag:") == null);
}
