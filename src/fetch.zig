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
const reader_connect_timeout_s = "5";
const reader_timeout_s = "15";
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
    content_type: []const u8 = "",
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

fn stagePrivateFile(ctx: *Context, comptime kind: []const u8, contents: []const u8) ![]const u8 {
    const path = try tmpName(ctx.io, ctx.arena, kind);
    errdefer Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
    var file = try Io.Dir.cwd().createFile(ctx.io, path, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(ctx.io);
    try file.setPermissions(ctx.io, .fromMode(0o600));
    if (contents.len > 0) {
        try file.writeStreamingAll(ctx.io, contents);
        try file.sync(ctx.io);
    }
    return path;
}

fn containsControl(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

/// Curl's config parser treats quotes and backslashes specially. Reject all
/// ASCII controls, then quote the URL so it cannot introduce another option.
fn curlUrlConfig(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (url.len == 0 or containsControl(url)) return error.InvalidUrl;

    var config: std.ArrayList(u8) = .empty;
    try config.appendSlice(arena, "url = \"");
    for (url) |byte| {
        if (byte == '\\' or byte == '"') try config.append(arena, '\\');
        try config.append(arena, byte);
    }
    try config.appendSlice(arena, "\"\n");
    return config.items;
}

fn stageCurlUrlConfig(ctx: *Context, comptime kind: []const u8, url: []const u8) ![]const u8 {
    return stagePrivateFile(ctx, kind, try curlUrlConfig(ctx.arena, url));
}

fn appendSourceCurlArgs(argv: *std.ArrayList([]const u8), arena: std.mem.Allocator, hdr_path: []const u8) !void {
    // This must be curl's first argument so ~/.curlrc cannot weaken policy.
    try argv.appendSlice(arena, &.{ "curl", "-q", "-sS" });
    try argv.appendSlice(arena, &.{ "--proto", "=https" });
    try argv.appendSlice(arena, &.{
        "--max-time", fetch_timeout_s,
        "-D",         hdr_path,
        "-H",         ua_header,
        "-H",         "Accept: application/json, text/html, application/xml, text/xml",
    });
}

const SourceStatus = enum { success, redirect_unsupported, failed };

fn classifySourceStatus(status: u32) SourceStatus {
    if ((status >= 200 and status < 300) or status == 304) return .success;
    if (status >= 300 and status < 400) return .redirect_unsupported;
    return .failed;
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
    switch (classifySourceStatus(resp.status)) {
        .success => {},
        .redirect_unsupported => {
            log("source fetch redirect HTTP {d} for {s}", .{ resp.status, url });
            return error.RedirectUnsupported;
        },
        .failed => {
            log("source fetch HTTP {d} for {s}", .{ resp.status, url });
            return error.FetchFailed;
        },
    }
    return resp;
}

/// One curl invocation. Body is captured on stdout; response headers are dumped
/// to a per-invocation temp file and parsed for status, ETag, Last-Modified,
/// and Retry-After. When `api_key` is non-empty, the Anthropic auth headers
/// are added (used only by the `api_probe` source kind); the key value is
/// staged in a 0600 temp file read via curl's `-H @file` form, so it never
/// appears in the process argument list (visible via ps) and is never logged.
/// Source requests are deliberately single-hop so curl never requests an
/// unvalidated redirect target.
fn curlOnce(ctx: *Context, url: []const u8, etag: []const u8, last_modified: []const u8, api_key: ?[]const u8) !Response {
    const a = ctx.arena;
    if (containsControl(url)) return error.InvalidUrl;
    if (containsControl(etag) or containsControl(last_modified)) return error.InvalidHeader;

    const hdr_path = try stagePrivateFile(ctx, "hdr", "");
    defer Io.Dir.cwd().deleteFile(ctx.io, hdr_path) catch {};
    var key_path: ?[]const u8 = null;
    defer if (key_path) |p| Io.Dir.cwd().deleteFile(ctx.io, p) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    try appendSourceCurlArgs(&argv, a, hdr_path);
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
            if (containsControl(key)) return error.InvalidHeader;
            const p = try stagePrivateFile(ctx, "key", try std.fmt.allocPrint(a, "x-api-key: {s}", .{key}));
            key_path = p;
            try argv.append(a, "-H");
            try argv.append(a, try std.fmt.allocPrint(a, "@{s}", .{p}));
            try argv.append(a, "-H");
            try argv.append(a, "anthropic-version: 2023-06-01");
        }
    }
    try argv.appendSlice(a, &.{ "--", url });

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
            // Do not let a proxy CONNECT or informational response donate a
            // content type to the final response.
            resp.content_type = "";
        } else if (headerValue(line, "etag:")) |v| {
            resp.etag = v;
        } else if (headerValue(line, "last-modified:")) |v| {
            resp.last_modified = v;
        } else if (headerValue(line, "retry-after:")) |v| {
            resp.retry_after = v;
        } else if (headerValue(line, "content-type:")) |v| {
            resp.content_type = v;
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

const BrowserStatus = enum { success, redirect_unsupported, failed };

fn classifyBrowserStatus(status: u32) BrowserStatus {
    if (status >= 200 and status < 300) return .success;
    if (status >= 300 and status < 400) return .redirect_unsupported;
    return .failed;
}

fn appendBrowserCurlArgs(argv: *std.ArrayList([]const u8), arena: std.mem.Allocator, url: []const u8, hdr_path: []const u8, resolve_pin: ?[]const u8) !void {
    try argv.appendSlice(arena, &.{
        "curl",           "-q",                                            "-sS",               "--proto",                         "=https",
        "--noproxy",      "*",                                             "--connect-timeout", reader_connect_timeout_s,          "--max-time",
        reader_timeout_s, "-D",                                            hdr_path,            "-A",                              browser_ua,
        "-H",             "Accept: text/html,application/xhtml+xml;q=0.9", "-H",                "Accept-Language: en-US,en;q=0.9",
    });
    if (resolve_pin) |pin| try argv.appendSlice(arena, &.{ "--resolve", pin });
    try argv.appendSlice(arena, &.{ "--", url });
}

fn htmlContentType(content_type: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const media_type = std.mem.trim(u8, content_type[0..end], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "text/html") or
        std.ascii.eqlIgnoreCase(media_type, "application/xhtml+xml");
}

/// Reject every non-global address before curl starts, then return one
/// `--resolve host:443:addr[,addr]` value so curl cannot perform a second DNS
/// lookup between validation and connection.
fn readerResolvePin(ctx: *Context, url: []const u8) !?[]const u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const component = uri.host orelse return error.InvalidUrl;
    const raw_host = switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| if (std.mem.indexOfScalar(u8, encoded, '%') == null) encoded else return error.InvalidUrl,
    };
    const host = std.mem.trim(u8, raw_host, "[]");
    if (host.len == 0) return error.InvalidUrl;
    if (host[host.len - 1] == '.') return error.InvalidUrl;

    if (Io.net.IpAddress.parse(host, 443)) |ip| {
        if (!publicIp(ip)) return error.PrivateAddress;
        return null;
    } else |_| {}

    const host_name = Io.net.HostName.init(host) catch return error.InvalidUrl;
    var result_buf: [32]Io.net.HostName.LookupResult = undefined;
    var results: Io.Queue(Io.net.HostName.LookupResult) = .init(&result_buf);
    try host_name.lookup(ctx.io, &results, .{ .port = 443 });

    var addresses: [32]Io.net.IpAddress = undefined;
    var count: usize = 0;
    while (results.getOneUncancelable(ctx.io)) |result| switch (result) {
        .canonical_name => {},
        .address => |address| {
            if (!publicIp(address)) return error.PrivateAddress;
            if (count == addresses.len) return error.TooManyAddresses;
            addresses[count] = address;
            count += 1;
        },
    } else |err| switch (err) {
        error.Closed => {},
    }
    if (count == 0) return error.NoAddressReturned;

    var pin: std.ArrayList(u8) = .empty;
    try pin.appendSlice(ctx.arena, host);
    try pin.appendSlice(ctx.arena, ":443:");
    for (addresses[0..count], 0..) |address, i| {
        if (i != 0) try pin.append(ctx.arena, ',');
        switch (address) {
            .ip4 => |ip4| try pin.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{f}", .{ip4})),
            .ip6 => |ip6| try pin.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "[{f}]", .{ip6})),
        }
    }
    return pin.items;
}

pub fn publicIp(ip: Io.net.IpAddress) bool {
    return switch (ip) {
        .ip4 => |v| publicIp4(v.bytes),
        .ip6 => |v| publicIp6(v.bytes),
    };
}

fn publicIp4(b: [4]u8) bool {
    if (b[0] == 0 or b[0] == 10 or b[0] == 127 or b[0] >= 224) return false;
    if (b[0] == 100 and (b[1] & 0xc0) == 64) return false;
    if (b[0] == 169 and b[1] == 254) return false;
    if (b[0] == 172 and b[1] >= 16 and b[1] <= 31) return false;
    if (b[0] == 192 and b[1] == 0 and b[2] == 0) return false;
    if (b[0] == 192 and b[1] == 0 and b[2] == 2) return false;
    if (b[0] == 192 and b[1] == 168) return false;
    if (b[0] == 198 and (b[1] == 18 or b[1] == 19)) return false;
    if (b[0] == 198 and b[1] == 51 and b[2] == 100) return false;
    if (b[0] == 203 and b[1] == 0 and b[2] == 113) return false;
    return true;
}

fn publicIp6(b: [16]u8) bool {
    if (allZero(b[0..]) or (allZero(b[0..15]) and b[15] == 1)) return false;
    if ((b[0] & 0xfe) == 0xfc or b[0] == 0xff) return false; // unique-local, multicast
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return false; // link-local
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0xc0) return false; // deprecated site-local
    if (allZero(b[0..12])) return false; // IPv4-compatible and other ::/96 forms
    if (allZero(b[0..10]) and b[10] == 0xff and b[11] == 0xff) return publicIp4(b[12..16].*);
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b and allZero(b[4..12]))
        return publicIp4(b[12..16].*); // NAT64 well-known prefix
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b and b[4] == 0x00 and b[5] == 0x01) return false;
    if (b[0] == 0x01 and b[1] == 0x00 and allZero(b[2..8])) return false; // discard-only 100::/64
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return false;
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x00 and b[3] == 0x00) return false; // Teredo
    if (b[0] == 0x20 and b[1] == 0x02) return publicIp4(b[2..6].*); // 6to4 embeds IPv4
    return true;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

/// One-shot HTTPS GET with a browser identity. Redirects are deliberately not
/// followed: curl must never make a second request to a URL that has not passed
/// the reader's SSRF policy. Returns `RedirectUnsupported` for every 3xx.
pub fn httpGetBrowser(ctx: *Context, url: []const u8) !Response {
    const a = ctx.arena;
    if (containsControl(url)) return error.InvalidUrl;
    const hdr_path = try stagePrivateFile(ctx, "reader-hdr", "");
    defer Io.Dir.cwd().deleteFile(ctx.io, hdr_path) catch {};
    const resolve_pin = try readerResolvePin(ctx, url);
    var argv: std.ArrayList([]const u8) = .empty;
    try appendBrowserCurlArgs(&argv, a, url, hdr_path, resolve_pin);
    const result = try std.process.run(a, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(16 * 1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            log("reader curl exit {d} for {s}: {s}", .{ code, url, std.mem.trim(u8, result.stderr, " \n\r") });
            return error.FetchFailed;
        },
        else => return error.FetchFailed,
    }

    const headers = Io.Dir.cwd().readFileAlloc(ctx.io, hdr_path, a, .limited(1024 * 1024)) catch return error.FetchFailed;
    var response = parseHeaders(headers);
    switch (classifyBrowserStatus(response.status)) {
        .success => {
            if (!htmlContentType(response.content_type)) return error.InvalidContentType;
            response.body = result.stdout;
            return response;
        },
        .redirect_unsupported => return error.RedirectUnsupported,
        .failed => return error.FetchFailed,
    }
}

/// POST a JSON payload to `url` (the structured-event webhook). Any transport
/// or non-2xx response is an error. The body is staged because
/// `std.process.run` cannot feed child stdin.
pub fn postJson(ctx: *Context, url: []const u8, json: []const u8) !void {
    return postJsonIdempotent(ctx, url, json, null);
}

/// POST with a stable downstream deduplication key.
pub fn postJsonIdempotent(ctx: *Context, url: []const u8, json: []const u8, idempotency_key: ?[]const u8) !void {
    const a = ctx.arena;
    const tmp = try stagePrivateFile(ctx, "post", json);
    defer Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
    const config_path = try stageCurlUrlConfig(ctx, "webhook", url);
    defer Io.Dir.cwd().deleteFile(ctx.io, config_path) catch {};

    const data_arg = try std.fmt.allocPrint(a, "@{s}", .{tmp});
    const key_header = if (idempotency_key) |key| blk: {
        if (containsControl(key)) return error.InvalidHeader;
        break :blk try std.fmt.allocPrint(a, "Idempotency-Key: {s}", .{key});
    } else ua_header;
    const argv = postCurlArgv(config_path, data_arg, key_header);
    const result = try std.process.run(a, ctx.io, .{ .argv = &argv, .stdout_limit = .limited(64 * 1024) });
    switch (result.term) {
        .exited => |code| if (code != 0 or !httpCodeIs2xx(result.stdout)) {
            log("webhook POST curl exit {d}", .{code});
            return error.WebhookFailed;
        },
        else => return error.WebhookFailed,
    }
}

/// Ping the dead-man's-switch heartbeat URL. Curl's fail mode makes every HTTP
/// 4xx/5xx response an error rather than a false success.
pub fn pingHeartbeat(ctx: *Context, url: []const u8) !void {
    const config_path = try stageCurlUrlConfig(ctx, "heartbeat", url);
    defer Io.Dir.cwd().deleteFile(ctx.io, config_path) catch {};
    const argv = heartbeatCurlArgv(config_path);
    const result = try std.process.run(ctx.arena, ctx.io, .{ .argv = &argv, .stdout_limit = .limited(64 * 1024) });
    switch (result.term) {
        .exited => |code| if (code != 0 or !httpCodeIs2xx(result.stdout)) return error.HeartbeatFailed,
        else => return error.HeartbeatFailed,
    }
}

fn postCurlArgv(config_path: []const u8, data_arg: []const u8, key_header: []const u8) [24][]const u8 {
    return .{
        "curl",       "-q",                             "-sS",           "--config",
        config_path,  "--proto",                        "=https",        "--fail-with-body",
        "--max-time", post_timeout_s,                   "-X",            "POST",
        "-H",         "Content-Type: application/json", "-H",            ua_header,
        "-H",         key_header,                       "--data-binary", data_arg,
        "-o",         "/dev/null",                      "--write-out",   "%{http_code}",
    };
}

fn heartbeatCurlArgv(config_path: []const u8) [16][]const u8 {
    return .{
        "curl",        "-q",           "-sS",    "--config",
        config_path,   "--proto",      "=https", "--fail-with-body",
        "--max-time",  post_timeout_s, "-o",     "/dev/null",
        "--write-out", "%{http_code}", "-H",     ua_header,
    };
}

fn httpCodeIs2xx(output: []const u8) bool {
    const text = std.mem.trim(u8, output, " \t\r\n");
    const status = std.fmt.parseInt(u16, text, 10) catch return false;
    return status >= 200 and status < 300;
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

test "parseHeaders captures content type" {
    const r = parseHeaders("HTTP/2 200\r\nContent-Type: application/json; charset=utf-8\r\n\r\n");
    try testing.expectEqualStrings("application/json; charset=utf-8", r.content_type);
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

test "webhook and heartbeat status policy accepts only 2xx" {
    try testing.expect(httpCodeIs2xx("200"));
    try testing.expect(httpCodeIs2xx(" 204\n"));
    inline for (.{ "302", "404", "429", "500", "", "garbage" }) |status| {
        try testing.expect(!httpCodeIs2xx(status));
    }
}

test "source status policy rejects redirects distinctly" {
    try testing.expectEqual(SourceStatus.success, classifySourceStatus(200));
    try testing.expectEqual(SourceStatus.success, classifySourceStatus(299));
    try testing.expectEqual(SourceStatus.success, classifySourceStatus(304));
    inline for (.{ 300, 302, 399 }) |status|
        try testing.expectEqual(SourceStatus.redirect_unsupported, classifySourceStatus(status));
    inline for (.{ 0, 400, 500 }) |status|
        try testing.expectEqual(SourceStatus.failed, classifySourceStatus(status));
}

test "source argv is HTTPS-only and never follows redirects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    try appendSourceCurlArgs(&argv, arena, ".headers");
    try testing.expectEqualSlices([]const u8, &.{ "curl", "-q", "-sS", "--proto", "=https" }, argv.items[0..5]);
    for (argv.items) |arg| {
        try testing.expect(!std.mem.eql(u8, arg, "-L"));
        try testing.expect(!std.mem.eql(u8, arg, "--location"));
        try testing.expect(!std.mem.eql(u8, arg, "--proto-redir"));
    }
}

test "curl URL config escapes syntax and rejects control injection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = try curlUrlConfig(arena, "https://example.com/a\\b\"c?token=secret");
    try testing.expectEqualStrings("url = \"https://example.com/a\\\\b\\\"c?token=secret\"\n", config);
    try testing.expectError(error.InvalidUrl, curlUrlConfig(arena, "https://example.com/a\nb"));
    try testing.expectError(error.InvalidUrl, curlUrlConfig(arena, "https://example.com/a\rb"));
    try testing.expectError(error.InvalidUrl, curlUrlConfig(arena, "https://example.com/a\tb"));
    try testing.expectError(error.InvalidUrl, curlUrlConfig(arena, "https://example.com/a\x7fb"));
}

test "staged curl URL config is private and contains the escaped URL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = Context{
        .io = testing.io,
        .arena = arena,
        .state_path = "",
        .log_path = "",
        .notify_cmd = null,
        .observed_at = "",
        .epoch_ms = 0,
    };

    const path = try stageCurlUrlConfig(&ctx, "test-url", "https://example.com/hook?token=secret");
    defer Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    var file = try Io.Dir.cwd().openFile(testing.io, path, .{});
    defer file.close(testing.io);
    const stat = try file.stat(testing.io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    const contents = try Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1024));
    try testing.expectEqualStrings("url = \"https://example.com/hook?token=secret\"\n", contents);
}

test "webhook and heartbeat argv contain only a config path and require HTTPS" {
    const secret_url = "https://example.com/hook?token=secret";
    const post_argv = postCurlArgv(".webhook-config", "@.body", ua_header);
    const heartbeat_argv = heartbeatCurlArgv(".heartbeat-config");

    inline for (.{ post_argv, heartbeat_argv }) |argv| {
        var has_https_policy = false;
        try testing.expectEqualStrings("-q", argv[1]);
        for (argv, 0..) |arg, index| {
            try testing.expect(!std.mem.eql(u8, arg, secret_url));
            try testing.expect(!std.mem.eql(u8, arg, "-L"));
            try testing.expect(!std.mem.eql(u8, arg, "--location"));
            if (std.mem.eql(u8, arg, "--proto") and index + 1 < argv.len) {
                has_https_policy = std.mem.eql(u8, argv[index + 1], "=https");
            }
        }
        try testing.expect(has_https_policy);
    }
}

test "browser fetch status policy rejects redirects distinctly" {
    try testing.expectEqual(BrowserStatus.success, classifyBrowserStatus(200));
    try testing.expectEqual(BrowserStatus.success, classifyBrowserStatus(299));
    try testing.expectEqual(BrowserStatus.redirect_unsupported, classifyBrowserStatus(300));
    try testing.expectEqual(BrowserStatus.redirect_unsupported, classifyBrowserStatus(302));
    try testing.expectEqual(BrowserStatus.redirect_unsupported, classifyBrowserStatus(399));
    try testing.expectEqual(BrowserStatus.failed, classifyBrowserStatus(0));
    try testing.expectEqual(BrowserStatus.failed, classifyBrowserStatus(404));
}

test "browser fetch argv is HTTPS-only and never enables redirects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    try appendBrowserCurlArgs(&argv, arena_state.allocator(), "https://example.com/article", ".headers", "example.com:443:93.184.216.34");
    var has_follow = false;
    var has_pin = false;
    var has_deadline = false;
    var bypasses_proxies = false;
    for (argv.items, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--location")) has_follow = true;
        if (std.mem.eql(u8, arg, "--resolve") and i + 1 < argv.items.len)
            has_pin = std.mem.eql(u8, argv.items[i + 1], "example.com:443:93.184.216.34");
        if (std.mem.eql(u8, arg, "--max-time") and i + 1 < argv.items.len)
            has_deadline = std.mem.eql(u8, argv.items[i + 1], reader_timeout_s);
        if (std.mem.eql(u8, arg, "--noproxy") and i + 1 < argv.items.len)
            bypasses_proxies = std.mem.eql(u8, argv.items[i + 1], "*");
    }
    try testing.expect(!has_follow);
    try testing.expect(has_pin);
    try testing.expect(has_deadline);
    try testing.expect(bypasses_proxies);
    try testing.expectEqualStrings("-q", argv.items[1]);
    try testing.expectEqualStrings("--proto", argv.items[3]);
    try testing.expectEqualStrings("=https", argv.items[4]);
    try testing.expectEqualStrings("https://example.com/article", argv.items[argv.items.len - 1]);
}

test "reader accepts only HTML media types" {
    try testing.expect(htmlContentType("text/html"));
    try testing.expect(htmlContentType("Text/HTML; charset=utf-8"));
    try testing.expect(htmlContentType(" application/xhtml+xml ; charset=utf-8"));
    inline for (.{ "", "text/plain", "application/json", "application/xml", "text/htmlx", "image/svg+xml" }) |value|
        try testing.expect(!htmlContentType(value));
}

test "reader IP policy rejects IPv4 special-use and metadata ranges" {
    inline for (.{
        "0.0.0.0",     "0.255.255.255",   "10.0.0.1",        "100.64.0.1",     "100.127.255.254",
        "127.0.0.1",   "169.254.169.254", "172.16.0.1",      "172.31.255.255", "192.0.0.1",
        "192.0.2.1",   "192.168.255.255", "198.18.0.1",      "198.19.255.255", "198.51.100.1",
        "203.0.113.1", "224.0.0.1",       "239.255.255.255", "240.0.0.1",      "255.255.255.255",
    }) |text| try testing.expect(!publicIp(try Io.net.IpAddress.parse(text, 443)));

    inline for (.{ "1.1.1.1", "8.8.8.8", "100.128.0.1", "172.32.0.1", "198.51.99.255", "223.255.255.254" }) |text|
        try testing.expect(publicIp(try Io.net.IpAddress.parse(text, 443)));
}

test "reader IP policy rejects IPv6 local embedded and special-use ranges" {
    inline for (.{
        "::",      "::1",     "::7f00:1",      "64:ff9b::7f00:1", "64:ff9b:1::1",
        "100::1",  "fc00::1", "fd00:ec2::254", "fe80::1",         "fec0::1",
        "ff02::1", "2001::1", "2001:db8::1",   "2002:7f00:1::1",
    }) |text| try testing.expect(!publicIp(try Io.net.IpAddress.parse(text, 443)));

    var mapped_loopback = [_]u8{0} ** 16;
    mapped_loopback[10] = 0xff;
    mapped_loopback[11] = 0xff;
    mapped_loopback[12] = 127;
    mapped_loopback[15] = 1;
    try testing.expect(!publicIp6(mapped_loopback));

    inline for (.{ "2001:4860:4860::8888", "2606:4700:4700::1111", "2002:0808:0808::1" }) |text|
        try testing.expect(publicIp(try Io.net.IpAddress.parse(text, 443)));
}
