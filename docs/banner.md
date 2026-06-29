# The `banner` subcommand

Last reviewed: 2026-06-18 · against fable-monitor 0.1.0

```
fable-monitor banner [text] [height]
```

Prints `FABLE` (or any `text` you pass) as a large terminal banner drawn with a
real TrueType font, the bundled blackletter face *Manufacturing Consent*. It is
a bit of flourish for the tool's namesake; it does not poll, touch the network,
or read/write any files, so it needs neither `curl` nor `zstd`.

| Argument | Default | Meaning |
|---|---|---|
| `text` | `FABLE` | The string to render. Only code points present in the font's cmap draw ink; others just advance. The font covers ASCII letters/digits and common punctuation. |
| `height` | `28` | Banner height in *pixel rows* (clamped to 8–200). Two pixel rows share one terminal line via half-blocks, so height 28 → 14 lines. Width is clamped to 120 columns; the glyphs scale down to fit. |

Examples:

```sh
fable-monitor banner               # FABLE at the default size
fable-monitor banner "FABLE 5"     # arbitrary text
fable-monitor banner FABLE 16      # shorter
```

## How it works

There is **no font or graphics dependency**, `src/banner.zig` parses the
TrueType outlines and rasterizes them itself, in the same std-only,
build-it-from-scratch spirit as [`src/parquet.zig`](data-export.md). The font is
embedded into the binary with `@embedFile`, so the subcommand works anywhere.

The pipeline:

1. **Parse the sfnt tables**, `head` (units/em, loca format), `maxp`, `hhea`,
   `hmtx` (advance widths), a format-4 `cmap` (code point → glyph id), `loca`,
   and `glyf`.
2. **Decode simple glyph outlines**, contours of on/off-curve points. Only
   simple glyphs are handled (the Latin capitals in this font are all simple;
   composite glyphs are skipped).
3. **Flatten quadratic Béziers** to line segments, inserting the implied
   on-curve midpoint between consecutive off-curve points.
4. **Rasterize** with a scanline fill using the **non-zero winding rule**, which
   correctly leaves the counters (the holes in `A`, `B`, …) empty.
5. **Emit half-blocks** (`▀ ▄ █`) so each character cell carries two vertical
   pixels, this doubles vertical resolution and makes the pixels roughly square
   in a normal terminal.

Scope is deliberately small: one row group of capitals at a handful of sizes.
It is not a general font renderer (no hinting, kerning, composite glyphs, or
sub-pixel antialiasing), see [design-decisions.md](design-decisions.md).

## The bundled font & its license

`src/assets/ManufacturingConsent-Regular.ttf` is licensed under the **SIL Open
Font License 1.1**, included verbatim at `src/assets/OFL.txt`. The OFL permits
bundling and redistribution (including embedding in the binary) provided the
license travels with it and the Reserved Font Name is respected. This is
**separate from the project's own MIT license** (`LICENSE`), which covers the
code only.

If you change `src/banner.zig`, the `banner` subcommand, or the bundled font,
update this document in the same change (see the
[doc-maintenance policy](README.md)).
