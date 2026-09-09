# Proposal v6 — a `Renderer` layer, then GPU desktop + native web backends

**Status:** All three phases implemented and verified 2026-09-09. Phase 1:
the `Renderer` seam. Phase 2: `GlCanvas` (desktop OpenGL), two full apps
(`widgets_demo_gl`, `desktop_shell_gl` + a new `Scrollbar` widget). Phase 3:
`Canvas2DCanvas` (browser Canvas2D via WASM host imports), one comprehensive
app (`web_shell`) — screenshot-verified live in Edge with genuinely native
antialiasing/text. Two real Tauraro compiler bugs and two real nebula bugs
(a dead slider drag, a freestanding-boot crash) found and fixed along the
way; see each phase's own status section for the full story.
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

### Phase 3 status — SHIPPED: Canvas2DRenderer, verified in a real browser

`toolkit/render/web/canvas2d_renderer.tr`'s `Canvas2DCanvas` — same
one-class-implements-both-Canvas-and-Renderer shape as `GlCanvas`, since
every shape reduces to a `js_rounded_rect`/`js_circle`/`js_fill_text` call
either way. `rounded_box`/`circle_ring` are the same two-pass border trick
`GlCanvas` uses (outer shape in the border colour, inset shape in the fill
colour on top) — real Canvas2D alpha compositing does the rest, no 3-way CPU
blend math needed here either. Every extern uses `c_int` (not Tauraro's own
64-bit `int`), so every value crosses into JS as a plain Number, never a
BigInt — much lighter host-page glue than `int`/`usize` would need.

New comprehensive example, `examples/web_shell/main.tr` +
`examples/web_shell/index.html`: Checkbox, a 3-way Radio group, Switch,
Slider + ProgressBar, and ScrollList (wheel-scrollable) — **every one of
these widgets needed ZERO changes** to run through `Canvas2DCanvas`; they
already routed through `Renderer` from phase 1, so setting `.renderer =
canvas2d_renderer_of(canvas)` each frame was the entire integration cost.
Screenshot-verified running in real Edge: genuinely crisp native rounded
corners/circles/text, visibly sharper than the baked-bitmap-font look on
every other tier — exactly the quality gap this phase set out to close.
Real click + slider-drag interaction confirmed live (the in-page "Recent
items" log and changing slider value moved in response to real OS-level
mouse input, not just a static render).

TextInput is NOT included — its persistent state is a live text buffer +
cursor position, and this file's "freestanding target: no module
initializers, persistent state is scalars only" constraint (same one
`render_web.tr` already documents) doesn't have a clean answer for that yet.
A real gap, left for a future pass, not attempted here.

**A second real bug found and fixed in `examples/web_demo` while getting
here** (unrelated to Canvas2D, but found staring at this same freestanding
pipeline): `render_web.tr`'s slider never actually dragged.
`Slider.drag_to()` only acts while `.dragging` is true, but `.dragging` is
only ever set by `.press_inside()` — which was never called anywhere in the
frame loop, so a freshly-constructed `Slider` (one is built every frame,
same "scalars only" constraint) always had `dragging = false` and
`drag_to()` was silently a no-op every frame. Fixed with a persistent
`_sl_dragging` scalar: `press_inside()` on the click that starts a drag,
then every following frame while the button stays down, manually prime the
fresh `Slider`'s own `dragging`/`origin_x`/`origin_w`/`origin_h` fields
(all `pub`) from that scalar and call `drag_to()` directly — calling
`press_inside()` again on those later frames would fail its own hit-test
as soon as the mouse moves away from the thumb's last position, which is
what a drag necessarily does.

**A third real, deeper bug found and fixed getting `examples/web_demo` to
even RUN at all under `--import-symbols`** (also unrelated to Canvas2D,
also found in this same investigation): the browser build crashed
immediately inside `nebula_heap_init` with a WASM "memory access out of
bounds". Root cause, confirmed by tracing the generated C: EVERY `pub
export def` on a freestanding target gets a compiler-injected "run once"
guard that initializes ALL reachable module-level globals the first time
ANY exported function is called (freestanding has no libc/_start to run
them the normal way) — correct in general, since the compiler can't know
which exported function a host calls first. But `toolkit/render/gamma.tr`'s
two 256-entry `List[int]` globals (`SRGB_TO_LINEAR`/`LINEAR_TO_SRGB`) need
heap allocation to build, and the very call that sets up the allocator
(`arena_init`, inside `nebula_heap_init` itself) runs AFTER that guard in
the SAME function — so the first allocation these tables need happens
before the arena knows its own base/size. A general compiler fix would need
either a new "static-backed, never-reallocated" `List` representation (real
scope: `List_i64`'s struct is one of the most fundamental, pervasively-used
types in the whole runtime — changing its layout is high-blast-radius, not
contained) or a separate compiler-internal bootstrap allocator independent
of the user's own arena (a new runtime concept). Neither attempted — instead
converted both tables from `List[int]` literals to `[int; 256]` fixed-size
arrays (an inline VALUE type, no heap pointer at all) with an explicit
lazy-init-on-first-use guard of their own (`_gamma_tables_ready`), so they
need no allocator, no arena, and no ordering relative to anything else —
correct on every target uniformly, not just freestanding. See
`toolkit/render/gamma.tr`'s own updated header for the full trace.

Old (pre-fix) content below, kept for the record of how this was
investigated:

Investigated 2026-09-09. Canvas2D needs Tauraro code to CALL a JS-provided
function (`js_rounded_rect` etc.) — the OPPOSITE direction from
`examples/web_demo`'s current wasm build, which imports NOTHING and only
shares a raw pixel buffer JS reads directly.

**First investigation pass wrongly assumed `--backend llvm` was required**
(that's what `docs/lang/22_compiling_and_cross_compilation.md` states for
"any wasm target"), and testing that path surfaced two real Tauraro compiler
bugs, both found, fixed, fixpoint-verified (gen1≡gen2≡gen3), and regression-
clean (`scripts/run_tests.ps1`, 20 files, only the 3 pre-existing unrelated
failures) in the tauraro repo:

1. `src/taumir/lower.tr`'s `extern "C"` registration only recognized
   Tauraro's own int/str/bool/f64 spellings, not the FFI `c_*` scalar family
   (`c_int`, `c_uint`, ...) — an extern declared with `c_int` params (the
   natural choice for `js_rounded_rect(x: c_int, ...)`) silently failed
   registration and the call site failed later with a confusing
   `"unsupported expression: call js_rounded_rect()"`. Fixed by widening the
   registration check to the same `c_*` list `src/codegen/c.tr` already
   recognizes (`_extern_sig_tag`).
2. `--backend llvm --target wasm`'s cross-link step had no
   `--allow-undefined` equivalent, so wasm-ld errored on the intentionally-
   unresolved import symbol. Real complication found while fixing it: `zig
   cc`'s own frontend REJECTS `-Wl,--allow-undefined`/`-Wl,--import-undefined`
   outright ("unsupported linker arg"), even though `zig wasm-ld` (the linker
   `zig cc` calls internally) fully supports both — confirmed by dry-running
   `zig cc -v` and replicating its own link line by hand. Fixed with a
   fallback in `src/main.tr`: only after the normal link fails with exactly
   "undefined symbol" does it retry via `zig wasm-ld` directly (bypassing zig
   cc's frontend for that one step), for `wasm32-unknown-unknown` specifically
   (no libc/crt objects to replicate, unlike the wasi case).

**Then the actual answer turned up: nebula doesn't use `--backend llvm` for
wasm at all.** `scripts/build-web.ps1` already uses the DEFAULT `--backend c`
(`--freestanding --emit c`), then invokes `zig build-exe` directly on the
emitted C — a completely different, already-working pipeline neither of the
two fixes above touches. Testing THAT pipeline with a `js_rounded_rect`
extern found the C backend already declares/calls it correctly with zero
changes needed — the only missing piece was a single `zig build-exe` flag:
**`--import-symbols`** ("(WebAssembly) import missing symbols from the host
environment" — `zig build-exe`'s own native equivalent of `--allow-undefined`,
with none of `zig cc`'s frontend restrictions). Added to
`scripts/build-web.ps1`.

**Verified completely end-to-end** with a standalone probe (`extern "C": def
js_rounded_rect(...)` + the same `@allocator`/`@free`/`@realloc`/`@calloc` +
`toolkit.platform.arena` hooks `render_web.tr` already uses): compiled via
`--target wasm --freestanding --emit c`, linked via `zig build-exe
--import-symbols`, inspected with `WebAssembly.Module.imports()` under Node
(`[{"module":"env","name":"js_rounded_rect","kind":"function"}]` — a real
host import, exactly as needed), then actually instantiated with a real JS
implementation and called — `js_rounded_rect` fired in JS with the correct
argument values round-tripped from Tauraro. This is the exact mechanism
`Canvas2DRenderer` needs for `ctx.roundRect`/`ctx.arc`/`ctx.fillText`.

**Not yet done:** rebuilding the FULL `web_demo` with the new flag to confirm
zero regression on the existing (import-free) build — attempted 4 times this
session and OOM'd every time during `zig build-exe -O ReleaseSmall`'s
compile of all 30 toolkit C files, but this reproduces IDENTICALLY with the
new flag removed too (confirmed by testing the exact same command without
`--import-symbols`), so it's this box's existing memory ceiling for that
specific heavy build, not something this change caused — worth re-running
once on a less memory-pressured run, but not blocking: the flag only changes
what happens to a symbol that would otherwise be a hard link error, so it's
a no-op for any build (like today's `web_demo`) with no unresolved externs.

**What this means for Phase 3:** `Canvas2DRenderer` (`toolkit/render/web/
canvas2d_renderer.tr`, the JS-import glue functions, wiring it into
`render_web.tr`) can be built next session — the mechanism it depends on is
now proven, not theoretical. The two LLVM-backend/wasm-link compiler fixes
also landed and are real, general improvements (any `extern "C"` using `c_*`
types, and `--backend llvm --target wasm32-unknown-unknown` generally) even
though they turned out not to be on nebula's actual critical path.

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
