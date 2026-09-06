# Antialiased rasterization for the Tauraro UI toolkit

**This specification documents the working rasterizer in `toolkit/`, verified on four execution 
tiers (hosted, Cortex-M, UEFI, desktop).** It is written as a guide for extending that 
rasterizer — adding new shape types, improving antialiasing, or understanding why certain design 
decisions are the way they are. It is NOT a theoretical treatment of rasterization; every pattern 
described here is production code in the toolkit right now.

**Read this before starting a new shape primitive or changing how colors blend.** The toolkit 
already has working implementations of rect fill, circle fill, rounded-rect fill/border, text 
blit, and supersampling antialiasing. The patterns are proven. Copy them.

---

## 0. The one architectural rule — for Tauraro

**Every shape primitive calls a single `Canvas.set_pixel(x, y, final_color)` method.** No 
coverage buffers, no secondary blending pass, no per-backend edge handling. Each backend 
(`BufferCanvas`, `FrameBuffer`, `GopCanvas`, `SdlCanvas`) implements the same four-method 
`Canvas` interface, and **shape code is identical across all four.**

The key constraint: `Canvas.set_pixel` takes **one final solid color and writes it**, period. 
No alpha, no read-back of the destination. This forces antialiasing to happen *before* the 
pixel write, not after.

```
shape function:
  for each pixel (x,y):
    count supersamples inside the shape boundary
    blend_color = mix(shape_color, backdrop_color, count/16)
    canvas.set_pixel(x, y, blend_color)
```

This is the core difference from the coverage-buffer architecture you might expect. It's not 
a limitation — it's the constraint that makes the same code work on a write-only UEFI 
framebuffer, a Cortex-M UART, an in-memory hosted buffer, and an SDL2 window, with zero 
backend-specific shape code.

---

## 1. Framebuffer layout — get this right first

UEFI GOP gives you `PixelBlueGreenRedReserved8BitPerColor` (BGRA, byte order B,G,R,X)
in the common case. Two traps:

- **`PixelsPerScanLine` is not `HorizontalResolution`.** The row stride is usually
  padded. Index with `y * pixels_per_scanline + x`, never `y * width + x`.
- **The framebuffer is uncached write-combining memory across PCIe.** Reads from it
  are catastrophically slow — often 100x a RAM read. Alpha blending *requires*
  reading the destination.

Therefore: **allocate a backbuffer in normal system RAM, do all drawing and blending
there, and blit finished rows to the GOP framebuffer with wide sequential writes.**
Never blend against the framebuffer directly. Blit only dirty rectangles.

```
struct Surface:
    pixels: *u32        # 0xAARRGGBB in RAM, host-endian
    width:  u32
    height: u32
    stride: u32         # in pixels, not bytes
```

Keep the backbuffer in one channel order and convert once during blit.

---

## 2. The blend function

Source-over compositing, integer, no division:

```
fn blend_channel(src: u32, dst: u32, a: u32) -> u32:
    # a in 0..255; result = (src*a + dst*(255-a)) / 255, correctly rounded
    t = src * a + dst * (255 - a) + 128
    return (t + (t >> 8)) >> 8

fn blend_pixel(dst_px: u32, r: u32, g: u32, b: u32, a: u32) -> u32:
    if a == 0:   return dst_px
    if a == 255: return (r << 16) | (g << 8) | b
    dr = (dst_px >> 16) & 0xFF
    dg = (dst_px >> 8)  & 0xFF
    db =  dst_px        & 0xFF
    return (blend_channel(r, dr, a) << 16)
         | (blend_channel(g, dg, a) << 8)
         |  blend_channel(b, db, a)
```

The `(t + (t >> 8)) >> 8` trick is exact division by 255 for all inputs in range. Use
it; do not use `>> 8` alone (that divides by 256 and makes everything 0.4% too dark,
which compounds visibly over many blends).

Early-out on `a == 0` and `a == 255`. In real UI most pixels are one or the other, and
these two branches are most of your performance.

### Offscreen layers must be premultiplied

The backbuffer is opaque, so it needs no alpha. But the moment you add offscreen
layers (a window buffer composited onto the desktop, a shadow, a cached glyph atlas),
store them **premultiplied**: `(r*a, g*a, b*a, a)`. Filtering or scaling
non-premultiplied RGBA pulls in undefined color from fully transparent pixels and
gives you dark or colored fringes. Premultiplied source-over is:

```
out = src + dst * (255 - src.a) / 255
```

---

## 3. Gamma — decide this deliberately

The GOP framebuffer holds sRGB-encoded values. Coverage is a *linear* quantity: a
pixel half covered by black ink emits half the light. Blending correctly means
decoding to linear, blending, re-encoding.

Concretely: black at 50% coverage over white is linear 0.5, which encodes to sRGB
**188**, not 128. Blend in sRGB space directly and every antialiased edge comes out
too heavy.

Two tables, 4.6 KB total, generated at build time or on first init:

```
SRGB_TO_LINEAR: [u16; 256]     # to 12-bit linear, 0..4095
LINEAR_TO_SRGB: [u8; 4096]
```

**Recommendation:** implement linear blending, but expose a `gamma_correct_coverage`
knob for text. Physically correct linear blending makes small dark-on-light text look
*thin and washed out* — this is why every real text stack fudges it. The standard fudge
is to reshape coverage before blending:

```
a' = pow(a/255, 1/contrast) * 255      # contrast ~ 1.2 to 1.45
```

precomputed as a 256-entry LUT. Ship one LUT for text, identity for shapes. Do not
"fix" thin text by abandoning linear blending for everything — that breaks gradients
and image compositing.

---

## 4. Coverage generation, per primitive

### 4a. Axis-aligned rectangle — exact, closed form

The rect has float (or 16.16 fixed) bounds `x0, y0, x1, y1`. For pixel `(i, j)`:

```
cx = max(0, min(x1, i+1) - max(x0, i))     # horizontal overlap, 0..1
cy = max(0, min(y1, j+1) - max(y0, j))
alpha = cx * cy
```

Split the loop into three vertical bands (top partial row, full rows, bottom partial
row) and three horizontal bands. The interior runs at `alpha = 255` and takes the
fast path in `blend_pixel`. This is exact — no approximation — and rects are most of
a UI, so make this path good.

### 4b. Circles, rounded rects, strokes — signed distance

Compute the signed distance `d` from the pixel center to the shape boundary, in
pixels, negative inside. Then:

```
alpha = clamp(0.5 - d, 0, 1)
```

This is the one-pixel-wide coverage ramp. Note **0.5 - d**, not `-d`: the ramp is
centered on the boundary and spans one pixel, half on each side. Getting this offset
wrong is the single most common antialiasing bug — shapes come out a half pixel too
fat or too thin, and adjacent shapes get seams.

Distance functions:

```
circle(p, c, r):        length(p - c) - r
rounded_rect(p, c, h, r):                     # h = half-extents, r = corner radius
    q = abs(p - c) - h + r
    length(max(q, 0)) + min(max(q.x, q.y), 0) - r
segment(p, a, b, w):                          # stroke of width w
    pa = p - a;  ba = b - a
    t = clamp(dot(pa, ba) / dot(ba, ba), 0, 1)
    length(pa - ba*t) - w*0.5
```

You need `length`, i.e. a square root, with no libm. Write a 16.16 fixed-point
integer sqrt (bit-by-bit restoring, ~16 iterations, or Newton seeded from a
`count_leading_zeros` estimate). Keep it in `math/fixed.tau` and unit-test it against
the hosted tier's f64 sqrt across the full input range.

**Accuracy caveat, so you know where the error is:** the true coverage of a unit
square cut by a straight line at distance `d` with normal angle `theta` is piecewise
*quadratic* in `d`, supported on `|d| <= (|cos theta| + |sin theta|) / 2`. The linear
ramp is exact at `theta = 0` and worst at 45 degrees, off by a few percent. That is
invisible. Do not implement the exact form.

**Curvature caveat:** the SDF ramp assumes the boundary is locally straight within the
pixel. For corner radii below ~2 px it visibly rounds off. Below that, fall back to
supersampling the corner region.

### 4c. Polygons and glyph outlines — sub-scanline coverage

This is the general case and the one text depends on. Use **N sub-scanlines per pixel
row with exact horizontal coverage.** N = 16 is the right default; N = 4 is visibly
stair-stepped on near-horizontal edges.

The error is `O(1/N)` vertically and *zero* horizontally, which matches how text
actually looks: horizontal precision is what the eye reads.

```
# One pixel row j. cov[] is a scratch array of width w, 16.16 fixed,
# where 65536 == fully covered. Zero it per row.

for s in 0 .. N-1:
    ys = j + (s + 0.5) / N

    # Collect crossings: every edge with y_top <= ys < y_bottom (half-open!)
    crossings = []
    for edge in edges:
        if edge.y0 <= ys < edge.y1:
            x = edge.x0 + (ys - edge.y0) * edge.dxdy
            crossings.push((x, +1))
        elif edge.y1 <= ys < edge.y0:
            x = edge.x0 + (ys - edge.y0) * edge.dxdy
            crossings.push((x, -1))

    sort crossings by x

    # Nonzero winding rule (TrueType and SVG default)
    winding = 0
    span_start = 0
    for (x, dir) in crossings:
        if winding == 0:
            span_start = x
        winding += dir
        if winding == 0:
            add_span(cov, span_start, x, 65536 / N)

# Emit
for i in 0 .. w-1:
    alpha = min(255, cov[i] >> 8)
    blend into backbuffer
```

The half-open `y0 <= ys < y1` test is what prevents double-counting at shared vertices.
Get it wrong and you get bright or dark pinholes where two edges meet.

`add_span` is where the horizontal exactness lives:

```
fn add_span(cov, xa, xb, weight):
    xa = clamp(xa, 0, w);  xb = clamp(xb, 0, w)
    if xb <= xa: return
    ia = floor(xa);  ib = floor(xb)
    if ia == ib:
        cov[ia] += (xb - xa) * weight          # both ends inside one pixel
    else:
        cov[ia] += (ia + 1 - xa) * weight      # left partial
        for i in ia+1 .. ib-1:
            cov[i] += weight                   # full interior
        if ib < w:
            cov[ib] += (xb - ib) * weight      # right partial
```

The interior loop is a flat add of a constant — that is your inner loop, keep it tight.

**Even-odd rule** (some SVG paths) is the same code with `winding` replaced by a
parity toggle: spans are simply consecutive pairs of crossings.

**Curves:** flatten quadratic and cubic Béziers to line segments before this stage,
subdividing until the flatness error is below ~0.1 px at the current scale. Do not
try to rasterize curves analytically.

**Allocation:** you need `cov[w]` plus an active-edge list. Both are per-row and
fixed-size — allocate once from the arena at surface creation, reuse every frame.
Never allocate per glyph. This keeps you compatible with the bump allocator.

**Glyph caching:** rasterize each (glyph, size) once into an 8-bit coverage bitmap in
an atlas, then text drawing becomes an alpha blit. Do this before you profile
anything else about text.

---

## 5. Anti-aliasing: supersampling, not coverage buffers (the Tauraro constraint)

Your `Canvas` interface has **no alpha channel and no destination read-back**. `set_pixel(x, y, color)` 
takes one final solid color and writes it, period. This rules out the coverage-buffer architecture 
in §4 and requires a different approach: **compute the blended color in your rasterizer code, then 
emit one final color per pixel.**

The working pattern, proven in `toolkit/ui/interp.tr` on all four tiers:

1. **Supersample on a regular grid** — 4×4 = 16 samples per pixel. All integer math, no floats.
2. **Test each subsample point** against the shape's boundary (circle SDF, rounded rect SDF, etc.).
3. **Count the samples inside** and blend: `blended = shape_color * (inside_count / 16) + backdrop_color * (16 - inside_count) / 16`.
4. **Call `set_pixel` once** with the final blended color.

This moves the blending logic from a separate pass into the caller's shape function, but it works 
on every backend — hosted, bare metal, UEFI, desktop — because it depends only on `Canvas.set_pixel`, 
not on framebuffer properties or architecture.

### 5a. Supersampling grid and boundary tests

For pixel `(i, j)`, test 16 points at `(i + dx, j + dy)` where `dx, dy ∈ {0.125, 0.375, 0.625, 0.875}`:

```
fn fill_circle_aa(x, y, radius, color, backdrop, canvas):
    inside = 0
    for dy in [0.125, 0.375, 0.625, 0.875]:
        for dx in [0.125, 0.375, 0.625, 0.875]:
            px = x + dx
            py = y + dy
            d = sqrt((px - center.x)^2 + (py - center.y)^2) - radius
            if d < 0:
                inside += 1
    
    blend_t = inside / 16
    r = shape_color.r * blend_t + backdrop.r * (1 - blend_t)
    g = shape_color.g * blend_t + backdrop.g * (1 - blend_t)
    b = shape_color.b * blend_t + backdrop.b * (1 - blend_t)
    canvas.set_pixel(i, j, rgb(r, g, b))
```

Use integer arithmetic: `sqrt` of integers, multiply by `(inside * factor + half) / 256` to avoid 
true division. See §5d below for the exact pattern.

### 5b. Border radius — smooth visual corners with 4×4 supersampling

`paint_rounded_rect_aa(x, y, w, h, radius, color, backdrop, canvas)` tests each corner's distance 
field at 16 subsamples. The corner quadrant equation, working in pixel-local coords `q`:

```
if both q.x > 0 and q.y > 0:
    d = sqrt(q.x*q.x + q.y*q.y) - radius      # circle arc
else:
    d = max(q.x, q.y)                         # straight edge region
```

The CSS overlap rule (clamping per-corner radii so they don't exceed box dimensions) must be 
applied before any pixel loop:

```
f = min(w / (r_tl + r_tr), w / (r_bl + r_br),
        h / (r_tl + r_bl), h / (r_tr + r_br))
if f < 1:
    r_tl = r_tl * f;  r_tr = r_tr * f;  r_bl = r_bl * f;  r_br = r_br * f
```

Select which radius to use by quadrant; test once per subsample.

### 5c. Borders — ring outline without ghosting

**Implemented 2026-09-05 as `paint_rounded_box_aa` / `fill_circle_ring_aa` in
`toolkit/ui/interp.tr`.** Everything below is what those two do; read them, don't re-derive it.

A border (stroke) is an outline, not a fill. Do not draw an outer rounded rect and then a smaller 
inner one: the two antialiased ramps will not cancel and edges ghost. Instead, for each subsample 
decide "inside outer? inside inner?" and count the annulus:

```
inside = (d_outer < 0) and not (d_inner < 0)
```

A single distance-field evaluation per subsample.

Worth being concrete about *why* the two-fill version fails, because "just pass the border color
as the backdrop" looks like it should work and doesn't. Wherever the two ramps overlap — which is
always, once `border_w` is 1-2px against a radius of 8-12 — the pixels beneath the inner fill's
ramp are themselves already a **border/ambient mix**, not solid border. Blending toward solid
border overshoots there and leaves a lighter halo tracing each corner. The information needed to
correct for it simply isn't available to the second call.

The toolkit's version generalizes the annulus test slightly: a bordered box has **three** regions,
not two (inner fill, ring, ambient), so each corner counts subsamples against both radii and mixes
all three colors at once (`mix3_color`). Because the inner rounded rect is inset by `border_w` on
every side with radius `radius - border_w`, its corner arc is **concentric** with the outer one —
so this is a plain two-radius annulus test sharing one center, not two separate distance fields.
Only the four corner squares pay the 16x cost; the straight edges are axis-aligned rectangles with
no curved boundary and stay exact `fill_rect` calls.

### 5d. Integer math for color blending

Avoid `float` entirely. Pack the 4 subsamples per x-coordinate into a counter:

```
# Tauraro style
fn blend_color_channels_int(shape_c: u32, backdrop_c: u32, inside_count: int) -> u32:
    # inside_count in 0..16; blend with fixed-point precision
    # result = shape_c * (inside_count / 16) + backdrop_c * (16 - inside_count) / 16
    out = 0
    for bit in 0 .. 8:
        s = (shape_c >> (bit * 8)) & 0xFF
        b = (backdrop_c >> (bit * 8)) & 0xFF
        t = s * inside_count + b * (16 - inside_count) + 8      # +8 for rounding
        blended = t / 16
        out = out | (blended << (bit * 8))
    return out
```

Or unroll for each channel separately if clarity matters more than compactness. The `+8` before 
divide-by-16 is the rounding correction (`(x + 2^(n-1)) / 2^n` = `round(x / 2^n)`).

### 5e. Caller supplies the backdrop color

The caller knows what is already behind the shape (e.g., the panel's background color). Pass it in 
and let the AA function blend to it. This is why every widget in `toolkit/ui/` has a `page_bg` field 
— it cascades the page background into each AA function call. Widgets that draw on different backgrounds 
need different backdrop colors; a function cannot know what it is blending onto.

For simple cases (a button on a solid background), `backdrop = page_bg` works. For complex 
composites, you either know the backdrop (draw order: draw the background, then call AA functions 
with that background color) or you don't (redesign the draw order).

---

## 6. Fills and colors

The `Style` system (`toolkit/ui/style.tr`) resolves `bg-` class tokens into solid RGB `u32` colors. 
Gradients are not yet shipped; start with solids.

### 6a. Solid colors

A `u32` packed as `0x00RRGGBB` (host-endian 32-bit little-endian on x86, which means bytes `[B,G,R,X]` 
in memory). The `Color` type is a wrapper:

```
pub class Color:
    pub value: u32
    pub def rgb(r: u32, g: u32, b: u32) -> u32:
        return (r << 16) | (g << 8) | b
```

**No alpha field — UI is opaque.** Antialiasing via supersampling (§5) handles edge softness; 
transparency is implemented at the shape boundary, not stored per-pixel in the framebuffer.

### 6b. Linear gradients (future)

When gradients ship: compute a parameter `t` for each pixel (affine in screen space, so constant 
`dt_dx` and `dt_dy`), then index a precomputed LUT with `t * 255` to get the final color. Store the 
LUT in linear light if gradient stops were authored in sRGB (fix the "muddy middle" problem — 
blue-to-yellow through sRGB is grey, through linear it is not). Example:

```
# Precompute at gradient creation
lut[i] = interpolate_linear(stop0, stop1, i / 255.0)

# Per-pixel, with t ∈ 0..1 computed once per row
idx = (t * 255) as u32
color = lut[idx]
```

Separable by channel; no need for a fancy 2D LUT.

### 6c. Image fills

Not yet in the toolkit. When they ship: sample from a baked image buffer with bilinear filtering, 
working in sRGB (good enough for photographs; linear sampling would require decoding each texel 
through a gamma LUT and is expensive). Always sample premultiplied if the image has an alpha channel 
— sampling non-premultiplied RGBA with bilinear drags in color from fully-transparent texels and 
fringes edges.

For UI icons (hard edges), pre-scale at load time in linear space, cache the result.

---

## 7. Fonts — baked bitmap atlas on all tiers

Text rendering is **offline TTF → bitmap atlas → lookup → blit**, same on all four tiers 
(hosted, Cortex-M, UEFI, desktop). This avoids curve math, float dependencies, and filesystem 
lookup on freestanding targets.

### 7a. Baking: from TTF to bitmap data

Use a system tool (Windows GDI+, macOS Core Graphics, or real fonttools on any OS) to render 
each glyph at a fixed size, supersampled, then downsampled. For this toolkit: 8×14 pixel cells,
ASCII 32–126 (95 glyphs), rendered with `scripts/bake-font.ps1` (GDI+, 4× supersampled) and
emitted as a raw `List[u8]` in `toolkit/text/font_data.tr` — **one 0-16 coverage byte per pixel**,
10640 bytes.

**This was a 1-bit-per-pixel threshold until 2026-09-05, and the change was worth it.** Hard-edged
8×14 letterforms were the single most visible "not smooth" thing anywhere in the toolkit — more
than any rounded corner — because text is most of what a UI actually shows and a glyph stem is
only 1-2px wide, so a threshold decision throws away most of the shape. Storing coverage instead
of a bit costs 8× the atlas size (still trivial: 10KB linked into the image) and makes text
rendering use the exact same blend as every other shape.

```
# Generated from JetBrainsMono.ttf -- one byte per pixel, 0..16 coverage
pub def font_coverage() -> List[u8]:
    return [0, 0, 3, 14, 16, ...]
```

Ship the font as binary data linked into the executable. No `.ttf` file, no parse, no filesystem 
dependency.

### 7b. Lookup and rendering

A `Font` type exposes one method:

```
pub def pixel_coverage(codepoint: int, col: int, row: int) -> int:
    # 0..16 coverage for (col, row) in the glyph cell. 0 = pure background,
    # 16 = pure foreground, anything between is a real antialiased edge.
    if codepoint < 32 or codepoint > 126:
        return 0          # out of range renders blank
    if col < 0 or col >= CELL_W or row < 0 or row >= CELL_H:
        return 0
    glyph_idx = codepoint - 32
    return COVERAGE[glyph_idx * CELL_W * CELL_H + row * CELL_W + col]
```

Every bounds failure returns 0 rather than raising — text content is not trusted input, and an
unsupported character must render as blank space, never garbage and never a crash.

The caller loops over the glyph cell and decides the color. This decouples font data from color 
rendering.

### 7c. Text rendering loop

```
fn draw_text(canvas, font, text, x, y, fg, bg):
    for i, codepoint in text:
        for col in 0 .. CELL_W-1:
            for row in 0 .. CELL_H-1:
                cov = font.pixel_coverage(codepoint, col, row)
                if cov == 16:
                    canvas.set_pixel(x + i*CELL_W + col, y + row, fg)
                elif cov > 0:
                    canvas.set_pixel(x + i*CELL_W + col, y + row, mix_color(fg, bg, cov))
```

Note the `bg` parameter, and note that it is the **same `mix_color` §5d defines** — a glyph edge
and a rounded-rect corner are the same problem and share the same code. The caller must say what
flat color the text is sitting on, exactly as for every other AA function (§5e). In the toolkit
this is `Interpreter.paint`'s ambient background for markup text, the widget's own resolved
surface color for widget labels, and the *hovered row's* fill for a list or dropdown row — which
is the kind of detail that is easy to get subtly wrong and shows up as a faint halo behind text.

Keep this as the ONE glyph loop in the codebase. There were three copies of it before 2026-09-05,
and changing the atlas format meant fixing the same blend math in three places.

### 7d. Layout constraint: glyph dimensions drive layout

The layout engine (`toolkit/layout/flex.tr`) exposes `glyph_w()` and `glyph_h()` to query the 
current font cell dimensions (8×14 for this toolkit). Any `<text>` node's measured size is 
`len(string) * glyph_w()` by `glyph_h()`, and layout sizes containers accordingly. No separate 
text-measurement API; the font dimensions are wired into flex directly.

### 7e. Subpixel positioning — later

At small sizes, quantizing each glyph's starting x to an integer pixel causes variable spacing. 
The fix: cache 4 rasterizations per glyph (x-positions at 0, 0.25, 0.5, 0.75 of a pixel) and 
index by the fractional part of the pen position. Costs 4× atlas space for glyphs actually drawn 
at fractional offsets; benefit is perceptibly tighter spacing. Out of scope for initial delivery 
(the baked atlas is already 4× the size needed for integer positioning).

### 7f. What is NOT included — the scope line

**Glyph shaping** (Indic reordering, Arabic right-to-left, ligatures, contextual substitution) 
is out of scope. The toolkit supports simple LTR runs only, using the `hmtx` advance width of 
each glyph and no GPOS kerning. Latin text with ASCII punctuation works perfectly; scripts that 
need real shaping need a separate engine (HarfBuzz, ICU, etc.).

**Color emoji** (CBDT, COLR, SBIX tables) are a separate pipeline entirely.

**Custom fonts at runtime** — currently the one baked font is the only option. Loading a second 
TTF from disk, baking it, and wiring it into the layout engine is a future phase.

---

## 8. Clipping and compositing

Child widgets are clipped to their parent's bounds. Hard rect clip is enough for now: skip 
pixel writes outside the clipping rectangle. Later, antialiased clipping (e.g., clipping child 
content to a rounded-corner parent) requires rasterizing the parent's shape into a *mask* and 
multiplying it into the shape's blend:

```
# Clip mask is precomputed once per parent shape
mask[x, y] = 16 if (x, y) inside rounded-rect shape, else 0

# When drawing child content, blend with the mask:
inside_count_child = 4   # from child shape's supersampling
inside_count_clipped = inside_count_child * mask[x, y] / 16
blended = blend(color, backdrop, inside_count_clipped)
```

This is not yet needed (the toolkit is single-panel, no nesting) but the architecture should 
accommodate it: a `Rect` clip works today; upgrade to a general mask type when needed.

---

## 10. Testing strategy — visual first, then edge cases

The toolkit tests differently than the coverage-buffer architecture in §4. All four tiers 
share the same source code, so verification is done once in hosted (fast iteration, take 
screenshots, eyeball the result) then re-run on bare metal/UEFI for regression.

### 10a. Hosted tier — iterate fast

1. **Write to PPM.** `toolkit/render/hosted/buffer.tr` already does this. Screenshot every 
   frame during development.
2. **Eyeball antialiasing.** Run `examples/hosted_demo` with a shape that has a curved boundary 
   (rounded-rect corner, circle). Pan and zoom in PPM viewer — the edge should be smooth, not 
   stair-stepped. This is a visual test, not a numeric one.
3. **Color accuracy.** For a shape of known RGB (e.g., red `0xFF0000` on white `0xFFFFFF` with 
   4/16 supersamples inside), measure the output pixel: should be approximately 
   `rgb(255, 127, 127)` (red mixed 25% with white). Off-by-one errors in blend math show up 
   here immediately.
4. **Seam test.** Draw two rects sharing an edge, same color. Visually, they should look like 
   one larger rect, no visible gap or overlap. This catches backdrop-color mismatches and 
   rounding errors in the blend.

### 10b. Multi-tier regression

Once hosted is correct:
1. **Cortex-M UART tier** — `scripts/build-bare.ps1 && scripts/run-bare.ps1` — captures PPM 
   over serial. Compares pixel-by-pixel against hosted reference.
2. **UEFI tier** — `scripts/run-uefi.ps1 -NoWindow` — boots, captures a screenshot via QEMU's 
   monitor, compares against hosted.
3. **Desktop tier** — `examples/desktop_demo` opens a live SDL2 window. Visual inspection; also 
   exercises input (mouse/keyboard) which the others don't.

The entire rasterizer (blur, antialiasing, color blending) is identical across all four because 
it is pure Tauraro code in `toolkit/ui/interp.tr`. Only the `Canvas` backend differs. If hosted 
renders correctly, bare metal and UEFI *will* render identically (barring Tauraro compiler bugs, 
which are tracked in `tau_bugs.txt`).

---

## 9. Build order

The toolkit already has steps 1-6 working on all tiers. The remaining work:

**DONE (verified on hosted, Cortex-M bare metal, UEFI, and desktop):**
1. Backbuffer + framebuffer blit with correct row stride.
2. Solid `fill_rect` with boundary clipping.
3. Hard rect clipping for nested layouts.
4. Baked bitmap font atlas + lookup + text rendering.
5. Flex layout engine (row/col/gap/pad/grow).
6. Parser (XML markup) + style cache + interpreter (tree walk, hit-test, handler dispatch).
7. 4×4 supersampling antialiasing for circles and rounded rects (5a, 5b).
8. Antialiased glyph atlas + blended text (7a-7c), replacing the 1-bit threshold.
9. Strokes (borders) rendered with antialiasing, single-pass, no ghosting (5c).
10. Ambient-backdrop threading through the whole recursive markup paint, so every
    `<panel radius-N>` and `<button>` is antialiased too, not just host-owned widgets (5e).

**IN PROGRESS / FUTURE:**
11. Linear/gamma-correct blending with sRGB LUT pair, plus a contrast-reshaped coverage LUT for
    text (3, 6b). The highest-value remaining item: every edge is currently blended in sRGB space
    and therefore comes out slightly too heavy. Not done yet because it changes every blended
    pixel on all four tiers at once and the Cortex-M tier has a known colour-value-dependent hang
    (`tau_bugs.txt` #13) that would make a regression there hard to attribute — do it with a
    per-tier before/after PPM diff in hand.
12. Clip masks for antialiased clipping to rounded-corner parents (8).
13. Linear gradients (6b).
14. Image fills and scaling (6c).

Each new shape primitive (circle, rounded rect, stroke) should be tested first in the hosted tier 
(fast iteration, easy screenshots) before deploying to bare metal. Every shape should support 
antialiasing via §5d pattern from day one.

---

## 11. Common traps — what the toolkit has already learned the hard way

- **Backdrop color mismatch in AA blending (5d).** If you pass the wrong `backdrop` color to a 
  `fill_circle_aa` function, antialiased edges blend to the wrong color and adjacent shapes show 
  visible seams or halos. The toolkit catches this by having every widget explicitly store its 
  page background color.
- **Integer overflow in subsample counting.** 16 subsamples × 16-bit coordinates = potential 
  overflow. Keep intermediate values small: test each subsample as a boolean, count in a small int, 
  only multiply by color channels when blending.
- **Blending on the wrong color depth.** The UEFI GOP framebuffer (`PixelBlueGreenRedReserved8BitPerColor`) 
  is BGRA but the toolkit's internal color is RRGGBB (host-endian `0x00RRGGBB`). These pack to 
  the same bytes (`[B,G,R,X]` in memory) — a happy accident — but if a new backend uses a 
  different pixel format, blending must happen before format conversion, not after. Blending BGRA 
  bytes directly will produce garbage.
- **Float dependencies on freestanding.** The toolkit is pure integer (no libm, no floats). The 
  only square root is `sqrt(u*u + v*v)` for circle/rounded-rect SDFs, implemented as a fixed-point 
  integer sqrt. Verify that `sqrt` does not leak a float cast anywhere; it will hang/crash on 
  Cortex-M.
- **Allocated buffers not freed in the bump allocator.** The toolkit's `FrameBuffer` in the 
  Cortex-M tier reuses one `StringBuilder` per row (via `.clear()`) rather than allocating fresh 
  ones. Allocating per-shape and relying on end-of-frame reset does not work if you actually 
  render multiple frames (the bump allocator never frees, so it grows unbounded). For interactive 
  demos on bare metal, implement per-frame arena reset separately (see project memory §4).
- **Row stride assumptions.** The UEFI GOP and some other framebuffers pad rows to a multiple of 
  4 bytes. `PixelsPerScanLine` is NOT the same as `HorizontalResolution`. Always use the stride 
  value the firmware provides.
- **Off-by-one in CSS border-radius clamping (5b).** The clamping formula has four denominators. 
  If any is zero (e.g., zero-width box), skip that division without crashing. Clamping each 
  radius individually to `min(w,h)/2` is wrong — it produces asymmetric results.
- **Glyph lookup out-of-bounds.** The font atlas covers ASCII 32–126 only. Codepoints outside 
  that range must return 0 from `Font.pixel_coverage` (render as blank) rather than crashing or 
  reading past the atlas end.
- **Forgetting the rounding correction in the blend.** `(fg*c + bg*(16-c)) / 16` truncates toward
  zero, biasing every blended pixel about half a level toward black. One pixel is invisible; a
  whole UI's worth of edges reads as a faint dark fringe around every corner and every glyph. Add
  `+ 8` before the divide (§5d). This shipped wrong for two days and was found by reading the
  spec, not by looking at the screen — the bias is real but below the threshold of "that looks
  broken", which is exactly why it needs to be a checklist item rather than a judgement call.
- **A blended shape whose backdrop is a *row*, not the widget.** Dropdown and list rows change
  color on hover/selection, so a label's correct backdrop is that row's resolved fill, not the
  widget's `bg`. Getting this wrong is invisible in the default state and only shows as a halo
  once the user hovers — check the interactive states, not just the first frame.
- **Two nested antialiased fills to make a border.** Covered fully in §5c; the summary is that no
  choice of backdrop color fixes it, because the second fill's ramp lands on pixels that are
  already a mix. Resolve all three regions in one pass.

---

## 12. How to add a new shape to the toolkit — Claude Code guide

You have been given a working toolkit with a specific rasterization architecture. This section 
is your roadmap for adding a new shape (e.g., a wedge/arc, a star, a shadow, a stroke) without 
breaking the four-tier architecture.

### 12a. The function signature

Every shape lives in `toolkit/ui/interp.tr` and follows this pattern:

```
fn paint_YOUR_SHAPE(
    center: Rect,          # or x, y, w, h — the bounding box or position
    color: u32,            # the shape's color, as 0x00RRGGBB
    page_bg: u32,          # the backdrop color (for AA blending) — this is KEY
    canvas: Canvas
):
    # iterate over bounding box
    # for each pixel, test 16 supersamples
    # blend and call canvas.set_pixel exactly once per pixel
```

The `page_bg` parameter is CRITICAL. It is the color that is already behind the shape. If you 
get this wrong, antialiased edges will blend to the wrong color. Look at `paint_circle_aa` 
or `paint_rounded_rect_aa` for reference.

### 12b. Supersampling loop template

```
fn paint_wedge_aa(cx: int, cy: int, radius: int, angle_start: int, angle_end: int,
                  color: u32, page_bg: u32, canvas: Canvas):
    # Bounding box (conservative)
    x0 = cx - radius;  x1 = cx + radius
    y0 = cy - radius;  y1 = cy + radius
    
    for py in y0 .. y1:
        for px in x0 .. x1:
            if px < 0 or px >= canvas.width() or py < 0 or py >= canvas.height():
                continue
            
            inside_count = 0
            # Subsample at 16 points: (px + dx, py + dy) where dx,dy ∈ {0.125, 0.375, 0.625, 0.875}
            for dy_int in [125, 375, 625, 875]:     # millifractions: 125 = 0.125
                for dx_int in [125, 375, 625, 875]:
                    # Sample point in world coordinates
                    sx = px + dx_int / 1000.0
                    sy = py + dy_int / 1000.0
                    
                    # Test whether (sx, sy) is inside the wedge
                    # Pseudocode: angle = atan2(sy - cy, sx - cx)
                    # if angle in [angle_start, angle_end] and dist(sx,sy to cx,cy) <= radius:
                    #   inside_count += 1
                    if is_inside_wedge(sx, sy, cx, cy, radius, angle_start, angle_end):
                        inside_count += 1
            
            # Blend: inside_count in 0..16
            blend_t = inside_count  # as fraction of 16
            r = (color_r * blend_t + page_bg_r * (16 - blend_t) + 8) / 16
            g = (color_g * blend_t + page_bg_g * (16 - blend_t) + 8) / 16
            b = (color_b * blend_t + page_bg_b * (16 - blend_t) + 8) / 16
            blended = rgb(r, g, b)
            
            canvas.set_pixel(px, py, blended)
```

The `+ 8` before divide-by-16 is the rounding correction; omit it and colors will be off by a 
half-LSB systematically.

### 12c. Integer-only math

Do NOT use floats. Keep sample offsets as integers (millifractions or fixed-point 16.16), and 
extract color channels with bit shifts:

```
color_r = (color >> 16) & 0xFF
color_g = (color >> 8) & 0xFF
color_b = color & 0xFF
```

The only expensive operation is distance calculations (sqrt). Use integer sqrt only. If you 
need an angle (atan2), precompute a lookup table at style-creation time, or use a 
`sign(dx) * sign(dy)` approximation for octants.

### 12d. Test flow — start with hosted

1. **Add the function to `toolkit/ui/interp.tr`.**
2. **Call it from the markup interpreter** (a new `<shape type="wedge" ... />` tag, or a 
   widget that uses it, or a standalone test).
3. **Run on hosted: `tauraroc --run examples/hosted_demo/main.tr > out.ppm`**
4. **Screenshot: open `out.ppm` in an image viewer. Inspect edges — are they smooth?**
5. **Once satisfied, re-run the other three tiers and compare pixel-by-pixel.** They should 
   be identical if the code is pure Tauraro.

If the bare-metal or UEFI tier produces different colors, it is a Tauraro compiler bug 
(check `tau_bugs.txt`), not a rasterizer bug.

### 12e. Integration: add the shape to a real widget

The widgets in `toolkit/ui/` (checkbox.tr, slider.tr, etc.) call rasterization functions 
to paint themselves. Example, from `switch.tr`:

```
fn paint(state: int, x: int, y: int, page_bg: u32, canvas: Canvas):
    # Paint the switch track (rounded rect)
    paint_rounded_rect_aa(
        x, y, width, height, radius,
        track_color, page_bg, canvas
    )
    # Paint the toggle knob (circle)
    knob_x = x + (state * knob_offset)
    paint_circle_aa(
        knob_x, y + height/2, knob_radius,
        knob_color, page_bg, canvas
    )
```

Your new shape should be called the same way — passed a color, backdrop, and canvas, and 
responsible for its own antialiasing.

### 12f. Performance notes (read-only, don't optimize prematurely)

- Hosted tier is fast; bare metal Cortex-M is slow. A 64×48 frame at 16 samples/pixel is 
  ~50k subsample tests. On a real M3 @ 80 MHz, this takes seconds.
- The toolkit does not presently cache rasterized shapes (except glyphs) — every frame 
  re-paints from scratch. This is fine for static UI (login screen, settings panel) but 
  not for animation. Interactive and animated demos will need a diffing/caching layer 
  (Phase 5 in the proposal).
- If a shape test is expensive (e.g., cubic Bézier point-in-curve), you will see the 
  perf hit first on bare metal. Test on hosted first with a large frame (1920×1080), 
  then scale down for bare metal.

### 12g. When you add a shape, check the following

- [ ] The function signature has `page_bg: u32` and uses it to blend.
- [ ] Supersampling loop tests exactly 16 points per pixel.
- [ ] Integer arithmetic only — no floats, no `sqrt` except for distance.
- [ ] Boundary clipping prevents out-of-bounds canvas writes.
- [ ] The shape renders identically on hosted and all three freestanding tiers.
- [ ] Antialiased edges are smooth, not stair-stepped, when zoomed in a PPM viewer.
- [ ] Adjacent shapes of the same color and touching edges show no visible seams or halos.

### 12h. When Claude Code is given a task

Refer to this spec. Tell the model:

> You are implementing a new shape in the Tauraro UI toolkit. The rasterizer uses **4×4 
> supersampling** (16 samples per pixel). Every shape function calls `Canvas.set_pixel` 
> exactly once per pixel with a **blended color** (shape color mixed with backdrop color 
> based on how many subsamples land inside the shape).
> 
> Use `toolkit/ui/interp.tr`'s `paint_circle_aa` and `paint_rounded_rect_aa` as templates. 
> Integer math only. The function signature must include `page_bg: u32` (the backdrop 
> color for AA blending) and `canvas: Canvas`.
> 
> Test first on hosted tier (fast), then verify the same code runs identically on 
> Cortex-M and UEFI by comparing PPM output pixel-by-pixel.

The model now has the constraint and the pattern. If it reaches for floats, SDFs, or 
coverage buffers, remind it of §5 and §12a.
