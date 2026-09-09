# Proposal v6 — a `Renderer` layer, then GPU desktop + native web backends

**Status:** Phases 1 and 2 implemented and verified 2026-09-09, including a
second full app (`desktop_shell_gl` + a new `Scrollbar` widget). Phase 3 is
blocked on two real compiler gaps, found and reported, not yet fixed (see
its own status section below).
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

### Phase 2 status — shipped

Landed as `toolkit/render/desktop/gl_bindings.tr` (OpenGL 3.3 core function
pointers, all resolved at runtime via `SDL_GL_GetProcAddress` — this is what
the `Pointer[void] as def(...)->...` compiler fix unblocked) and
`toolkit/render/desktop/gl_canvas.tr`'s `GlCanvas`, ONE class implementing
BOTH `Canvas` and `Renderer` rather than the separate `SdlCanvas`+
`SoftwareRenderer` pair the software path uses. That collapse turned out to
be the right shape, not just a shortcut: `Canvas.fill_rect` and
`Renderer.rounded_rect` are the same GPU primitive (a quad, filled via a
rounded-box signed-distance-field fragment shader, `radius = 0` degenerating
exactly to a flat rect), so one shared shader/VAO/VBO serves every draw call
in the toolkit. `circle`/`circle_ring` are that same primitive again, sized
so the radius is maximal (a circle is a maximally-rounded square) — so the
whole renderer is really one draw call shape (`rounded_rect`) plus a two-pass
border variant (draw the border-colored shape, then a smaller inset
fill-colored shape on top, replacing the software path's single-pass
three-way `mix3_color_hq` math entirely, because REAL alpha blending can
just composite pass 2 onto pass 1 the way a real vector renderer would) and a
textured-quad variant for glyphs (the three baked atlases, uploaded once as
GL_RED textures, sampled straight from the SAME 0-16 coverage bytes the CPU
path bakes, just linearly rescaled to 0-255).

Gamma correctness: `SDL_GL_FRAMEBUFFER_SRGB_CAPABLE` is requested at context
creation and `GL_FRAMEBUFFER_SRGB` enabled after — every shape/text uniform
color is converted sRGB→linear on the CPU (reusing `toolkit/render/gamma.tr`'s
existing LUT, not a shader approximation) and the GPU handles linear↔sRGB
around every blend automatically, i.e. the same principle
`toolkit/ui/interp.tr`'s `mix_color_hq` hand-implements on the CPU, done by
fixed-function hardware instead.

Verified visually (screenshot, `examples/gl_smoke/main.tr` +
`scripts/build-desktop-gl.ps1`): flat rect, rounded rect, bordered rounded
box, filled circle, ring, a real alpha-blended translucent overlay (0xFFFFFF
at alpha=90 over the dark background reads as a correctly-blended mid-gray,
not opaque white), and text at two sizes, all correct in one frame.

Two real bugs found closing the loop, worth recording:
1. **`glUniform4f` on a `vec3` shader uniform silently no-ops** on this
   driver (first screenshot: every shape rendered pure black — coverage/AA
   were correct, only color was wrong, because the color uniform was never
   actually written). No GL error, no Tauraro-side error — this is exactly
   the "shader bugs show up as wrong colours with no useful diagnostic"
   risk this section warned about before starting. Fixed by adding a real
   `glUniform3f` binding and matching every vec3-uniform call site to it.
2. Calling `Str.len(...)`/`Str.char_at(...)` **without importing `Str`** from
   `string.str` doesn't fail where you'd expect — the compiler silently
   treats the bare `Str` identifier as an ordinary (undeclared) value and
   shifts it in as the call's first positional argument instead of reporting
   "Str is not defined" at the `Str.len(...)` site. Cost real debugging time
   before the missing import was spotted; every other file in this toolkit
   that uses `Str` already imports it, so this had never surfaced before.

Also required syncing the freshly-fixed compiler into
`~/.taupkg/bin/tauraroc-windows-x64/tauraroc.exe` — nebula's build scripts
call the taupkg SDK copy, not the tauraro repo's own `tauraroc.exe`, and the
SDK copy still predated the `Pointer[void] as def(...)->...` fix.

**Wired into the full widget demo**, `examples/widgets_demo_gl/main.tr` — a
near-exact copy of `examples/widgets_demo/main.tr` with exactly two kinds of
change: `gl_canvas_open(...)` instead of `SdlCanvas.open_vsync(...)` (every
existing `Canvas`-typed call site keeps compiling unchanged, phase 1's whole
point), and each host-painted widget's `.renderer` field reassigned from its
default `SoftwareRenderer` to `gl_renderer_of(canvas)`. Two small additions
made this a true drop-in: `GlCanvas.draw_shadow` (same six-layer
concentric/fading approach `SdlCanvas.draw_shadow` uses, but each layer is a
real antialiased rounded GPU draw instead of a flat square-cornered rect —
free here where SDL's own version deliberately skipped rounding) and
`Caps.gl()`/`gl_canvas.tr`'s own `caps()` (same per-backend-module pattern
`sdl_canvas.tr` already follows). Screenshot-verified: header card + shadow,
tabs, checkbox, 3-way radio group, switch, slider + progress bar, dropdown,
scroll list, and the OK/CANCEL buttons all render correctly through the GPU
path in one frame — the complete widget set, not just the isolated shapes
`gl_smoke` exercises. The markup-driven chrome tree and `draw_text`/
`paint_section_label` still call the CPU rasterizer's `Canvas.set_pixel`/
`fill_rect` per pixel (correct output, still real GPU alpha-blended pixels,
just not batched into one SDF draw call per shape) — fully batching those
too means routing `toolkit.ui.interp`'s scene-graph execution itself through
`Renderer`, a separate follow-up this session didn't need in order to prove
the wiring.

**A third real bug, found only once the full demo was running (not visible
in `gl_smoke`'s single-frame-shaped test): the whole window flickered.**
Root cause: `render_diff_to`'s skip-unchanged-commands optimization assumes
each `present()` leaves the previous frame's pixels in place except for what
just changed — true for `SdlCanvas` (SDL2's 2D renderer's present behaves
like a copy/blit), **false for real OpenGL double buffering**, which
`SDL_GL_SwapWindow` performs as an actual flip between two distinct physical
buffers. Anything diffing skipped in one frame simply never got drawn into
the OTHER buffer, so the window alternated between two different partial
states every other frame — a flicker, not a one-time glitch. Fixed by
switching the GL demo's chrome to `render_to` (unconditional full repaint,
matching every widget below it, which already repaints its fixed rect
unconditionally every frame for the same reason) and drawing the header
shadow every frame instead of only on repaint transitions. Verified fixed
via three screenshots ~200ms apart, pixel-identical. This is a real
constraint for any future `Renderer` backend built on true double/multiple
buffering (not just GL) — diffing-based partial repaint is only safe on a
backend whose present() is copy-semantics, and needs to be an explicit,
checked assumption rather than implicit going forward.

**Second full app, `examples/desktop_shell_gl/main.tr`** — desktop_shell
(menu bar, `Router`-driven Dashboard/Data Table/Settings pages, Table,
Slider, Checkbox/Radio/Switch, TextInput) GPU-accelerated end to end from
the start, applying the `render_to`-not-`render_diff_to` lesson immediately
rather than re-discovering it. Also added a genuinely new widget this pass:
`toolkit/ui/scrollbar.tr`'s `Scrollbar` — a real draggable, proportional-
thumb vertical scrollbar (click-thumb-to-drag, click-track-to-page, sized by
content/viewport ratio the way a real OS scrollbar is), since neither
`Table` nor `ScrollList` had ever had a VISIBLE scroll indicator, only silent
mouse-wheel support. It's a pure mirror/drive control (owns its own
`offset`, synced against `Table.scroll_offset` each frame the same way
`ProgressBar` mirrors `Slider`), so it works with any content that already
exposes `scroll_offset`/`max_offset`/`visible_rows`/`len(...)`, not just
`Table`. Wired onto the Data Table page, right of the grid. Screenshot-
verified: Dashboard opens correctly by default, Data Table (with the table
+ scrollbar both rendering) reachable and correct, no flicker (this file
used `render_to` from the start, unlike `widgets_demo_gl` which found the
bug the hard way first).

**A testing-process gotcha, not a code bug:** repeated screenshot automation
across several app launches left a stale OS cursor position/focus state that
caused the FIRST post-fix launch to appear to open on the wrong page — root-
caused by moving the mouse away before launch and re-testing clean, which
fixed it immediately, and confirmed further by reproducing the identical
symptom against the untouched original SdlCanvas-based `desktop_shell` too
(so it was never GL-path-specific). Also confirmed mid-session: this box's
screenshot/click automation needs `SetProcessDPIAware()` called in the
*automation* process itself, or `GetClientRect`/`ClientToScreen`/click
coordinates land in a scaled, wrong coordinate space against a real
per-monitor-DPI-aware window (the same DPI mismatch class documented
earlier for `gl_smoke`'s window-rect capture).

---

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

### Phase 3 status — blocked on two real compiler gaps, not yet fixed

Investigated 2026-09-09, before writing any nebula code, because Phase 2's
own experience (the `Pointer[void] as def(...)->...` cast) showed it's worth
confirming the compiler mechanism exists before building on top of it.
Canvas2D needs Tauraro code to CALL a JS-provided function (`js_rounded_rect`
etc.) — the OPPOSITE direction from `examples/web_demo`'s current wasm build,
which imports NOTHING and only shares a raw pixel buffer JS reads directly.

Tauraro does have the right *syntax* for this — `extern "C": def
js_rounded_rect(...) -> void` with no body, documented in
`docs/lang/17_extern_and_ffi.md` — but two separate gaps stand between that
syntax and a working browser import today:

1. **The LLVM backend rejects calling an extern function with no
   definition at all** — `"unsupported expression: call js_rounded_rect()"`.
   Since `docs/lang/22_compiling_and_cross_compilation.md` requires
   `--backend llvm` for any wasm target, this alone blocks the approach
   regardless of the second gap.
2. **The wasm link path has no `--allow-undefined`/`-Wl,--import-undefined`
   wiring** in `src/main.tr`'s wasm build command — wasm-ld's default is to
   *error* on an unresolved function symbol rather than leave it as an
   import, so even with gap 1 fixed, linking would fail rather than produce
   an importable `.wasm`.

Neither gap was fixed this session (this is a Tauraro compiler change, not
a nebula one — the same category as the `Pointer[void] as def(...)->...`
fix that unblocked phase 2, but this one needs LLVM-backend codegen work
plus a linker-flag change, not a single codegen case). Also could not be
empirically end-to-end verified even with those two fixed: this box has no
bundled/system `zig` and the system `clang` (mingw64) lacks a wasm
sysroot/wasi-libc, so `--target wasm-wasi`/`--target wasm` currently fail
before reaching the link step regardless (a separate, pre-existing gap, not
new to this investigation). A real `--allow-undefined`-style build would
need either a working wasm sysroot on this box or a session where that's
set up first.

**What this means for Phase 3:** `Canvas2DRenderer` as designed (JS-import
based, native `ctx.roundRect`/`ctx.arc`/`ctx.fillText`) is not buildable yet.
`WebCanvas`'s existing raw-pixel-buffer approach still works unchanged and
is not affected by any of this. Phase 3 is ON HOLD pending a decision: fix
the two compiler gaps first (a real, scoped compiler task, likely smaller
than phase 2's shader work but touching LLVM backend internals rather than
one codegen case), set up a working wasm sysroot and re-verify, or defer
Phase 3 indefinitely and treat `WebCanvas` as the web tier's permanent
ceiling.

---

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
