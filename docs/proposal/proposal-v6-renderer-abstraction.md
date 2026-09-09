# Proposal v6 — a `Renderer` layer, then GPU desktop + native web backends

**Status:** Phase 1 implemented and verified 2026-09-09. Phases 2/3 not started.
In response to a direct request to (1) gamma-correct blend (done, see
RASTERIZER.md's own status note) (2) GPU-accelerate every UI tier except
UEFI/bare-metal (3) give the browser tier native Canvas2D quality. This
proposes HOW, in three phases, because (2) and (3) both need the same
foundational change first and neither is a small edit.

## Phase 1 status — shipped

`toolkit/render/renderer.tr` (the `Renderer` interface) and
`toolkit/render/software_renderer.tr` (`SoftwareRenderer`, a thin pass-through
to the existing rasterizer) landed as designed. All 11 widget files
(`checkbox`, `radio`, `switch`, `slider`, `progress`, `dropdown`, `menubar`,
`table`, `textinput`, `tabs`, `list`) now hold a `renderer: Renderer` field
defaulted in `.init()` and call through it instead of calling
`toolkit.ui.interp`'s rasterizer functions directly. Zero call-site changes
for any example or consumer — `widgets_demo` and `desktop_shell` both rebuilt
and re-ran with pixel-identical output, and all 10 `verified-examples/*.tr`
regression tests re-ran clean (81+6+7+... assertions, 0 failures).

**A real compiler gap, found and worked around:** assigning a concrete class
value directly to a field declared with an interface type
(`w.renderer = SoftwareRenderer.init()`) fails to compile — the generated C
wants the interface's fat-pointer representation and a bare class pointer
isn't one ("incompatible types ... from type 'SoftwareRenderer *'"). Routing
the same value through a function whose own return type is the interface
(`software_renderer.tr`'s `default_renderer() -> Renderer`) compiles and runs
correctly — the implicit wrap only happens at a parameter/return type
boundary, not a plain field assignment. Confirmed with a minimal two-class
repro before settling on the workaround. Not fixed in the compiler this
session; every widget's `.init()` calls `default_renderer()` rather than
`SoftwareRenderer.init()` directly.

---

## 1. Why this isn't a quick follow-on to the gamma fix

Gamma correction and the analytic-coverage rewrite (proposal-v5's sibling work)
both stayed inside `toolkit/ui/interp.tr`'s existing functions — same signatures,
same callers, zero blast radius beyond "the blended colour is now more correct."

GPU rendering and a Canvas2D web backend are not that. Right now, every rounded
rect, circle, and glyph in this toolkit is computed *by this Tauraro code*,
per-pixel, on the CPU, in `toolkit/ui/interp.tr`'s `paint_rounded_rect_aa` /
`paint_rounded_box_aa` / `fill_circle_aa` / `fill_circle_ring_aa` / `draw_text`.
Every widget (`Slider`, `Checkbox`, `Radio`, `Switch`, `Dropdown`, `MenuBar`,
`Table`, ...) calls those functions directly — 18+ call sites across the
toolkit (see the file-by-file list in section 3). A GPU backend needs those
*same call sites* to instead submit work to a shader; a Canvas2D backend needs
them to instead call `ctx.roundRect`/`ctx.arc`/`ctx.fillText` in the browser.
Neither is possible without an indirection point between "a widget wants to
draw a rounded rect" and "here's how that actually gets rendered on this
platform" — which doesn't exist today. `Canvas` is that indirection for
*primitive* fills/pixels, but shapes are computed *above* Canvas, in Tauraro,
identically for every backend. That's exactly why software rendering has been
"one Canvas implementation, everywhere" — and exactly why GPU/Canvas2D can't
plug in without a new seam.

## 2. What already told us this, and what's changed since

`proposal-v4-renderer-architecture.md` sketched precisely this seam (a
`Renderer` above `Canvas`) in 2026-09 and **deliberately deferred it**, for a
measured reason: SDL_GPU wasn't available (SDL2, not SDL3), the existing SDL2
path was *already* hardware-accelerated for compositing, and a streaming-
texture GPU path measured 1.8x **slower** than per-pixel draws for the
workload tested. That measurement is still correct and still the reason
"switch to Vulkan/OpenGL because it's a GPU" isn't the right frame (see the
conversation this proposal follows from).

What's different now: the ask isn't "make frames faster" (they're already
fast — 219fps measured), it's "make antialiasing itself run on the GPU, with
real hardware alpha blending, because that's what actually gives Skia/browser
output its quality" — and "give the browser tier the browser's own renderer."
Both are legitimate, and both are architecture decisions, not perf ones. This
proposal says yes to both, phased so the risky part (touching every call site)
ships alone and fully regression-tested before either new backend exists.

## 3. Phase 1 — the `Renderer` seam (software-only, zero visual change)

Introduce `toolkit/render/renderer.tr`:

```
pub interface Renderer:
    def rounded_rect(x, y, w, h, radius, fg, bg) -> void
    def rounded_box(x, y, w, h, radius, border_w, fill, border, ambient) -> void
    def circle(cx, cy, r, fg, bg) -> void
    def circle_ring(cx, cy, r, ring_w, fill, ring, ambient) -> void
    def text(font, str, x, y, fg, bg) -> void
```

`toolkit/render/software_renderer.tr`'s `SoftwareRenderer` wraps the EXISTING
`interp.tr` functions verbatim — this is a pure move, not a rewrite; the
analytic-coverage/gamma-correct math already there doesn't change at all.

Every widget call site (`Slider.paint`, `Checkbox.paint`, `Radio.paint`,
`Switch.paint`, `Dropdown.paint`, `MenuBar.paint`, `Table.paint`, `TextInput.paint`,
`Interpreter.build_scene`'s corresponding `exec_cmds`/`execute_diff`) changes
from `paint_rounded_rect_aa(c, ...)` to `renderer.rounded_rect(...)`, taking a
`Renderer` alongside the `Canvas` they already take. `Interpreter` and every
host-painted widget gain a `renderer: Renderer` field, defaulted to
`SoftwareRenderer.init()` — so an example that never opts into anything new
keeps compiling and rendering byte-identically. This phase's own regression
gate is exactly that: every `verified-examples/*.tr` re-run with **pixel-identical**
output, the same discipline steps C/D/E used when the scene graph and grid
layout landed.

This is the part with real blast radius (touches every shape-drawing call
site in the toolkit) and real value in isolation (it's what makes the next
two phases additive instead of invasive) — worth landing and re-verifying on
its own before building anything on top of it.

## 4. Phase 2 — `GLRenderer`, desktop only

A new `toolkit/render/desktop/gl_renderer.tr`. Desktop specifically, because
this needs a real GPU context SDL2's 2D renderer doesn't expose:

- `SdlCanvas` gains `open_gl_accelerated(title, w, h) -> SdlCanvas`, alongside
  `open()`/`open_vsync()` (additive, same pattern — existing examples
  untouched), creating an `SDL_GLContext` instead of an `SDL_Renderer`.
- Each `Renderer` method becomes: build a quad covering the shape's bounding
  box, run a fragment shader computing the exact same analytic SDF this
  toolkit's CPU path now uses (section 4b's formula, in real GLSL floats this
  time — no isqrt trick needed, the GPU has native `sqrt`/`length`), and let
  **real GPU alpha blending** (`glBlendFunc`) composite it — the first place
  in this toolkit that isn't limited by `Canvas`'s "no alpha channel, no
  destination read-back" rule, because a GPU backend doesn't share bare-metal
  framebuffers' constraints.
- Text: glyphs upload once as a GPU texture (the existing baked atlas data,
  unchanged), sampled in the fragment shader — no change to font baking.
- Verification is necessarily visual (screenshot + zoom, the same method
  that verified the analytic-coverage and gamma work), not pixel-identical
  to the software path — a GPU path computing in true floating point WILL
  differ from the software path at the sub-pixel level, same honest caveat
  proposal-v4 already made about a GPU tier.

**Real risk, stated plainly:** this is genuine OpenGL/GLSL work — a new
rendering pipeline, shader compilation, vertex buffers — verified by
screenshot on a box that has been measurably resource-constrained this
session (builds have intermittently failed from memory pressure even for
already-proven code). Shader bugs often show up as black screens or wrong
colours with no useful compiler diagnostic, unlike a Tauraro type error.
This phase should be scoped as its own session, not squeezed in after phase 1.

## 5. Phase 3 — Canvas2D web backend, opt-in, browser-native quality

A new `toolkit/render/web/canvas2d_renderer.tr`, implementing the same
`Renderer` interface via WASM imports into a handful of new JS functions
(`js_rounded_rect`, `js_circle`, `js_circle_ring`, `js_fill_text`) that call
real `ctx.roundRect`/`ctx.arc`/`ctx.fillText` with a real CSS font — browser-
native antialiasing, hinting, and text shaping, instead of this toolkit's own
rasterizer blitted as a pixel buffer.

**The explicit tradeoff, stated up front so it's a decision and not a
surprise later:** this is no longer pixel-identical to the other three tiers
— that's the whole point (native quality *instead of* cross-tier identity,
for this one platform, exactly the fork proposal-v4 flagged rather than
backed into). `WebCanvas` (the existing raw-buffer backend) stays as-is and
keeps being what UEFI/bare-metal-style verification compares against if that
ever matters for web; `Canvas2DRenderer` is a second, explicitly-opted-into
web backend, not a replacement.

## 6. Sequencing and what I'd need from you before starting

| | Step | Ships alone? | Risk |
|---|---|---|---|
| 1 | `Renderer` seam, `SoftwareRenderer` only | Yes — pixel-identical, fully regression-tested | Low (mechanical, wide) |
| 2 | `GLRenderer`, desktop | Yes — new opt-in path, `open()`/`open_vsync()` untouched | High (new pipeline, visual-only verification, this box's resource flakiness) |
| 3 | `Canvas2DRenderer`, web | Yes — new opt-in path, `WebCanvas` untouched | Medium (JS glue + a deliberate quality/identity tradeoff) |

I'd recommend landing **Phase 1 first, fully verified, before touching GL or
JS** — it's the part every later step needs, and it's cheap to get definitely
right (existing pixel-exact tests catch any regression immediately). Phases 2
and 3 are independent of each other once Phase 1 lands; either can go first,
or in parallel across sessions.
