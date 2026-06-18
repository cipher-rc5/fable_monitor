//! Render text as a terminal banner using a TrueType font, from scratch.
//!
//! `fable-monitor banner [text] [height]` prints "FABLE" (or the given text)
//! drawn with the bundled blackletter font (Manufacturing Consent, SIL OFL —
//! see src/assets/OFL.txt). There is no font/graphics dependency: we parse the
//! TrueType outlines, rasterize them, and print Unicode half-blocks. This is in
//! the same std-only, build-it-ourselves spirit as src/parquet.zig.
//!
//! Scope, deliberately minimal (it only has to draw a few capital letters):
//!   * `cmap` format 4, `loca` (short or long), simple `glyf` outlines only
//!     (no composite glyphs — the Latin capitals in this font are all simple);
//!   * quadratic Béziers flattened to line segments;
//!   * scanline polygon fill with the non-zero winding rule (handles counters
//!     like the bowls of A/B);
//!   * half-block output (▀▄█) so two vertical pixels share one character cell,
//!     which also makes the pixels roughly square in a normal terminal.
//!
//! Format reference: the Apple/Microsoft TrueType spec (sfnt tables).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The bundled font, embedded into the binary so `banner` works anywhere.
const font_ttf = @embedFile("assets/ManufacturingConsent-Regular.ttf");

const default_height: usize = 28; // pixel rows (→ 14 text lines via half-blocks)
const max_width: usize = 120; // clamp banner width to a sane terminal column count
const bezier_steps: usize = 12; // line segments per quadratic curve

// --- big-endian readers over the font bytes --------------------------------
fn u16be(d: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, d[o..][0..2], .big);
}
fn i16be(d: []const u8, o: usize) i16 {
    return std.mem.readInt(i16, d[o..][0..2], .big);
}
fn u32be(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .big);
}

const Font = struct {
    data: []const u8,
    units_per_em: u16,
    num_glyphs: u16,
    loc_long: bool, // indexToLocFormat: true → 32-bit loca offsets
    num_h_metrics: u16,
    loca: usize,
    glyf: usize,
    hmtx: usize,
    cmap4: usize, // offset of the chosen format-4 cmap subtable

    fn load(d: []const u8) !Font {
        if (d.len < 12 or u32be(d, 0) != 0x00010000) return error.NotTrueType;
        const num_tables = u16be(d, 4);
        var head: usize = 0;
        var maxp: usize = 0;
        var hhea: usize = 0;
        var cmap: usize = 0;
        var loca: usize = 0;
        var glyf: usize = 0;
        var hmtx: usize = 0;
        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = 12 + i * 16;
            const tag = d[rec .. rec + 4];
            const off = u32be(d, rec + 8);
            if (std.mem.eql(u8, tag, "head")) head = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea = off;
            if (std.mem.eql(u8, tag, "cmap")) cmap = off;
            if (std.mem.eql(u8, tag, "loca")) loca = off;
            if (std.mem.eql(u8, tag, "glyf")) glyf = off;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx = off;
        }
        if (head == 0 or maxp == 0 or cmap == 0 or loca == 0 or glyf == 0 or hhea == 0 or hmtx == 0)
            return error.MissingTable;

        // Pick a format-4 cmap subtable, preferring the Microsoft (3,1) one.
        const ntab = u16be(d, cmap + 2);
        var chosen: usize = 0;
        var t: usize = 0;
        while (t < ntab) : (t += 1) {
            const rec = cmap + 4 + t * 8;
            const plat = u16be(d, rec);
            const sub = cmap + u32be(d, rec + 4);
            if (u16be(d, sub) != 4) continue;
            if (chosen == 0 or plat == 3) chosen = sub;
        }
        if (chosen == 0) return error.NoCmap4;

        return .{
            .data = d,
            .units_per_em = u16be(d, head + 18),
            .num_glyphs = u16be(d, maxp + 4),
            .loc_long = i16be(d, head + 50) != 0,
            .num_h_metrics = u16be(d, hhea + 34),
            .loca = loca,
            .glyf = glyf,
            .hmtx = hmtx,
            .cmap4 = chosen,
        };
    }

    /// Map a Unicode code point to a glyph id via the format-4 cmap (0 = .notdef).
    fn glyphIndex(f: Font, cp: u21) u16 {
        const d = f.data;
        const t = f.cmap4;
        const seg_x2 = u16be(d, t + 6);
        const seg = seg_x2 / 2;
        const end_o = t + 14;
        const start_o = end_o + seg_x2 + 2; // +2 for reservedPad
        const delta_o = start_o + seg_x2;
        const range_o = delta_o + seg_x2;
        const c: u16 = if (cp > 0xFFFF) return 0 else @intCast(cp);
        var i: usize = 0;
        while (i < seg) : (i += 1) {
            if (c > u16be(d, end_o + i * 2)) continue;
            const start = u16be(d, start_o + i * 2);
            if (c < start) return 0;
            const delta = i16be(d, delta_o + i * 2);
            const ro = u16be(d, range_o + i * 2);
            if (ro == 0) return @intCast((@as(i32, c) + delta) & 0xFFFF);
            const addr = range_o + i * 2 + ro + 2 * (c - start);
            const g = u16be(d, addr);
            if (g == 0) return 0;
            return @intCast((@as(i32, g) + delta) & 0xFFFF);
        }
        return 0;
    }

    fn advanceWidth(f: Font, gid: u16) u16 {
        const idx = if (gid < f.num_h_metrics) gid else f.num_h_metrics - 1;
        return u16be(f.data, f.hmtx + idx * 4);
    }

    /// Byte range of glyph `gid` within the glyf table (empty span = blank glyph).
    fn glyphSpan(f: Font, gid: u16) struct { start: usize, end: usize } {
        const d = f.data;
        if (f.loc_long) {
            return .{ .start = f.glyf + u32be(d, f.loca + gid * 4), .end = f.glyf + u32be(d, f.loca + (gid + 1) * 4) };
        }
        return .{ .start = f.glyf + @as(usize, u16be(d, f.loca + gid * 2)) * 2, .end = f.glyf + @as(usize, u16be(d, f.loca + (gid + 1) * 2)) * 2 };
    }
};

const Pt = struct { x: f64, y: f64, on: bool };
const Edge = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

// TrueType simple-glyph flag bits.
const fl_on_curve = 0x01;
const fl_x_short = 0x02;
const fl_y_short = 0x04;
const fl_repeat = 0x08;
const fl_x_same = 0x10; // when x is short: sign bit; else: x unchanged
const fl_y_same = 0x20;

/// Decode the simple-glyph outline `gid` into edges (line segments) in font
/// units, offset horizontally by `pen_x`. Composite/empty glyphs append nothing.
fn glyphEdges(f: Font, a: Allocator, gid: u16, pen_x: f64, edges: *std.ArrayList(Edge)) !void {
    const d = f.data;
    const span = f.glyphSpan(gid);
    if (span.end <= span.start) return; // blank glyph (e.g. space)
    const gs = span.start;
    const n_contours = i16be(d, gs);
    if (n_contours < 0) return; // composite — unsupported (not needed for capitals)
    const nc: usize = @intCast(n_contours);

    const end_pts = try a.alloc(u16, nc);
    var k: usize = 0;
    while (k < nc) : (k += 1) end_pts[k] = u16be(d, gs + 10 + k * 2);
    const n_pts: usize = end_pts[nc - 1] + 1;

    const ins_len = u16be(d, gs + 10 + nc * 2);
    var off = gs + 10 + nc * 2 + 2 + ins_len;

    // Flags (with run-length REPEAT expansion).
    const flags = try a.alloc(u8, n_pts);
    var idx: usize = 0;
    while (idx < n_pts) {
        const fbyte = d[off];
        off += 1;
        flags[idx] = fbyte;
        idx += 1;
        if (fbyte & fl_repeat != 0) {
            var rep = d[off];
            off += 1;
            while (rep > 0) : (rep -= 1) {
                flags[idx] = fbyte;
                idx += 1;
            }
        }
    }

    // X then Y coordinates as accumulated deltas.
    const pts = try a.alloc(Pt, n_pts);
    var x: i32 = 0;
    for (0..n_pts) |p| {
        const fb = flags[p];
        if (fb & fl_x_short != 0) {
            const dx: i32 = d[off];
            off += 1;
            x += if (fb & fl_x_same != 0) dx else -dx;
        } else if (fb & fl_x_same == 0) {
            x += i16be(d, off);
            off += 2;
        }
        pts[p] = .{ .x = @as(f64, @floatFromInt(x)) + pen_x, .y = 0, .on = fb & fl_on_curve != 0 };
    }
    var y: i32 = 0;
    for (0..n_pts) |p| {
        const fb = flags[p];
        if (fb & fl_y_short != 0) {
            const dy: i32 = d[off];
            off += 1;
            y += if (fb & fl_y_same != 0) dy else -dy;
        } else if (fb & fl_y_same == 0) {
            y += i16be(d, off);
            off += 2;
        }
        pts[p].y = @floatFromInt(y);
    }

    // Flatten each contour.
    var first: usize = 0;
    for (end_pts) |last| {
        try flattenContour(a, pts[first .. last + 1], edges);
        first = last + 1;
    }
}

/// Turn one contour (its on/off-curve points) into edges. Off-curve points are
/// quadratic control points; two consecutive off-curve points imply an
/// on-curve midpoint between them.
fn flattenContour(a: Allocator, pts: []const Pt, edges: *std.ArrayList(Edge)) !void {
    if (pts.len < 2) return;

    // Insert implied on-curve midpoints so no two off-curve points are adjacent.
    var nodes: std.ArrayList(Pt) = .empty;
    for (pts, 0..) |cur, k| {
        try nodes.append(a, cur);
        const next = pts[(k + 1) % pts.len];
        if (!cur.on and !next.on) {
            try nodes.append(a, .{ .x = (cur.x + next.x) / 2, .y = (cur.y + next.y) / 2, .on = true });
        }
    }

    // Rotate so traversal starts on an on-curve point.
    var s: usize = 0;
    while (s < nodes.items.len and !nodes.items[s].on) : (s += 1) {}
    if (s == nodes.items.len) return; // all off-curve: degenerate, skip
    const L = nodes.items.len;
    const at = struct {
        fn get(ns: []const Pt, start: usize, len: usize, j: usize) Pt {
            return ns[(start + j) % len];
        }
    }.get;

    const start_pt = nodes.items[s];
    var cx = start_pt.x;
    var cy = start_pt.y;
    var j: usize = 1;
    while (j < L) {
        const node = at(nodes.items, s, L, j);
        if (node.on) {
            try edges.append(a, .{ .x0 = cx, .y0 = cy, .x1 = node.x, .y1 = node.y });
            cx = node.x;
            cy = node.y;
            j += 1;
        } else {
            const end = if (j + 1 < L) at(nodes.items, s, L, j + 1) else start_pt;
            try quad(a, edges, cx, cy, node.x, node.y, end.x, end.y);
            cx = end.x;
            cy = end.y;
            j += 2;
        }
    }
    // Close the contour.
    try edges.append(a, .{ .x0 = cx, .y0 = cy, .x1 = start_pt.x, .y1 = start_pt.y });
}

/// Flatten a quadratic Bézier (P0, control C, P1) into `bezier_steps` segments.
fn quad(a: Allocator, edges: *std.ArrayList(Edge), x0: f64, y0: f64, cx: f64, cy: f64, x1: f64, y1: f64) !void {
    var px = x0;
    var py = y0;
    var i: usize = 1;
    while (i <= bezier_steps) : (i += 1) {
        const tt = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(bezier_steps));
        const u = 1.0 - tt;
        const bx = u * u * x0 + 2 * u * tt * cx + tt * tt * x1;
        const by = u * u * y0 + 2 * u * tt * cy + tt * tt * y1;
        try edges.append(a, .{ .x0 = px, .y0 = py, .x1 = bx, .y1 = by });
        px = bx;
        py = by;
    }
}

/// Build all edges for `text`, in font units (y-up), advancing the pen per glyph.
fn layout(f: Font, a: Allocator, text: []const u8) !std.ArrayList(Edge) {
    var edges: std.ArrayList(Edge) = .empty;
    var pen_x: f64 = 0;
    for (text) |ch| {
        const gid = f.glyphIndex(ch);
        try glyphEdges(f, a, gid, pen_x, &edges);
        pen_x += @floatFromInt(f.advanceWidth(gid));
    }
    return edges;
}

/// Rasterize `edges` to a `w`×`h` 1-bit bitmap (row-major, true = ink) using
/// the non-zero winding rule. `edges` endpoints are already in pixel space.
fn rasterize(a: Allocator, edges: []const Edge, w: usize, h: usize) ![]bool {
    const bmp = try a.alloc(bool, w * h);
    @memset(bmp, false);

    var xs: std.ArrayList(struct { x: f64, dir: i32 }) = .empty;
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const ys = @as(f64, @floatFromInt(row)) + 0.5;
        xs.clearRetainingCapacity();
        for (edges) |e| {
            const down = e.y1 > e.y0;
            const lo = if (down) e.y0 else e.y1;
            const hi = if (down) e.y1 else e.y0;
            if (ys < lo or ys >= hi) continue; // half-open avoids double-counting vertices
            const tt = (ys - e.y0) / (e.y1 - e.y0);
            try xs.append(a, .{ .x = e.x0 + tt * (e.x1 - e.x0), .dir = if (down) 1 else -1 });
        }
        std.mem.sort(@TypeOf(xs.items[0]), xs.items, {}, struct {
            fn lt(_: void, p: @TypeOf(xs.items[0]), q: @TypeOf(xs.items[0])) bool {
                return p.x < q.x;
            }
        }.lt);

        var wind: i32 = 0;
        for (xs.items, 0..) |cr, k| {
            wind += cr.dir;
            if (k + 1 >= xs.items.len or wind == 0) continue;
            const span_lo = cr.x;
            const span_hi = xs.items[k + 1].x;
            var c: usize = @intFromFloat(@max(0.0, @ceil(span_lo - 0.5)));
            const c_end_f = @floor(span_hi - 0.5);
            if (c_end_f < 0) continue;
            const c_end: usize = @min(w - 1, @as(usize, @intFromFloat(c_end_f)));
            while (c <= c_end) : (c += 1) bmp[row * w + c] = true;
        }
    }
    return bmp;
}

/// Render `text` as a half-block banner to stdout. `height` is in pixel rows
/// (clamped); 0 selects the default.
pub fn render(io: Io, a: Allocator, text: []const u8, height: usize) !void {
    const f = try Font.load(font_ttf);
    const edges = try layout(f, a, text);
    if (edges.items.len == 0) return error.NothingToRender;

    // Ink bounding box in font units.
    var min_x: f64 = std.math.floatMax(f64);
    var min_y: f64 = std.math.floatMax(f64);
    var max_x: f64 = -std.math.floatMax(f64);
    var max_y: f64 = -std.math.floatMax(f64);
    for (edges.items) |e| {
        min_x = @min(min_x, @min(e.x0, e.x1));
        min_y = @min(min_y, @min(e.y0, e.y1));
        max_x = @max(max_x, @max(e.x0, e.x1));
        max_y = @max(max_y, @max(e.y0, e.y1));
    }
    const span_x = max_x - min_x;
    const span_y = max_y - min_y;
    if (span_x <= 0 or span_y <= 0) return error.NothingToRender;

    const want_h: f64 = @floatFromInt(if (height == 0) default_height else @max(@as(usize, 8), @min(@as(usize, 200), height)));
    // Fit to the requested pixel height, but clamp width to the terminal.
    const scale = @min(want_h / span_y, @as(f64, @floatFromInt(max_width)) / span_x);
    const w: usize = @max(1, @as(usize, @intFromFloat(@ceil(span_x * scale))));
    const h: usize = @max(1, @as(usize, @intFromFloat(@ceil(span_y * scale))));

    // Transform edges into pixel space (y flipped: ink top → row 0).
    for (edges.items) |*e| {
        e.x0 = (e.x0 - min_x) * scale;
        e.x1 = (e.x1 - min_x) * scale;
        e.y0 = (max_y - e.y0) * scale;
        e.y1 = (max_y - e.y1) * scale;
    }

    const bmp = try rasterize(a, edges.items, w, h);

    var buf: [8192]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;
    var ry: usize = 0;
    while (ry < h) : (ry += 2) {
        // Build the line, then trim trailing blanks before emitting.
        var line: std.ArrayList(u8) = .empty;
        var c: usize = 0;
        while (c < w) : (c += 1) {
            const top = bmp[ry * w + c];
            const bot = ry + 1 < h and bmp[(ry + 1) * w + c];
            const glyph: []const u8 = if (top and bot) "\u{2588}" else if (top) "\u{2580}" else if (bot) "\u{2584}" else " ";
            try line.append(a, glyph[0]);
            for (glyph[1..]) |b| try line.append(a, b);
        }
        const trimmed = std.mem.trimEnd(u8, line.items, " ");
        try out.writeAll(trimmed);
        try out.writeAll("\n");
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Tests run against the embedded font, so they are deterministic.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "big-endian readers" {
    const d = [_]u8{ 0x12, 0x34, 0xFF, 0xFE };
    try testing.expectEqual(@as(u16, 0x1234), u16be(&d, 0));
    try testing.expectEqual(@as(i16, -2), i16be(&d, 2));
    try testing.expectEqual(@as(u32, 0x1234FFFE), u32be(&d, 0));
}

test "font loads and maps capitals to real glyphs" {
    const f = try Font.load(font_ttf);
    try testing.expectEqual(@as(u16, 1200), f.units_per_em);
    // F A B L E must all resolve to non-.notdef glyphs with advance widths.
    for ("FABLE") |ch| {
        const gid = f.glyphIndex(ch);
        try testing.expect(gid != 0);
        try testing.expect(f.advanceWidth(gid) > 0);
    }
}

test "glyph F decodes to a non-empty outline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Font.load(font_ttf);
    var edges: std.ArrayList(Edge) = .empty;
    try glyphEdges(f, a, f.glyphIndex('F'), 0, &edges);
    try testing.expect(edges.items.len > 0);
}

test "quadratic flatten emits bezier_steps segments ending at the endpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var edges: std.ArrayList(Edge) = .empty;
    try quad(a, &edges, 0, 0, 10, 10, 20, 0);
    try testing.expectEqual(bezier_steps, edges.items.len);
    try testing.expectApproxEqAbs(@as(f64, 20), edges.items[edges.items.len - 1].x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), edges.items[edges.items.len - 1].y1, 1e-9);
}
