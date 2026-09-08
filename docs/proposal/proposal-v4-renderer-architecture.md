# Proposal v4 — Scene graph, two renderers, capability flags

**Status:** draft for review. Supersedes nothing yet; v3's phases 1–3 are done and
this builds on them.

Origin: the architecture sketch in `proposole-v4.md`, turned into a spec and
checked against what the repo actually does today.

---

## 1. What this changes, in one sentence

Today the engine **paints directly** through a four-method `Canvas`. v4 has the
engine **emit a scene graph** — resolved rects, styles and paint commands — which a
`Renderer` then executes however it likes, including on a GPU.

That single change is what unlocks everything else in the sketch, and it is also the
riskiest thing in it, because `Canvas` is the exact boundary the project's central
claim rests on:

> a new platform costs one `Canvas` implementation (four methods) plus an input source

That claim is currently true and *tested* — four backends, `render_widgets.tr` and
`examples/widgets_demo/main.tr` produce the same panel at the same pixel offsets on
SDL2 and on bare UEFI firmware. v4 raises the price of a new platform from "four
methods" to "a Renderer". That is worth doing, but it should be a decision, not a
side effect.

---

## 2. What is already true

Worth stating plainly, because the sketch describes several things that exist:

| Sketch box | Status today |
|---|---|
| Markup parser + runtime interpreter | ✅ `toolkit/ui/parser.tr`, `interp.tr` |
| Style system, Tailwind-compatible | ✅ 242-colour palette, real scales, 81 assertions |
| Flexbox layout | ✅ `toolkit/layout/flex.tr` — row/col, gap, per-side padding, margins, fractions, justify/items |
| Event system + hit testing | ✅ `hit_test`, `dispatch`, `EventHandler` |
| **Extreme Renderer** | ✅ **this is the current rasterizer.** UEFI GOP, Cortex-M, hosted buffer — all shipping |
| WASM build of the existing rasterizer | ✅ phase 2, `toolkit/render/web/canvas.tr` |
| Grid layout | ❌ not started |
| Widget tree + state management | ❌ widgets are host-owned and rebuilt per frame |
| Animation + transitions | ❌ nothing; `Switch.tick()` is a hand-rolled counter |
| Theme + design tokens | ⚠️ partial — the palette is there, no theme indirection |
| Capability flags | ⚠️ implicit and ad-hoc (`SdlCanvas.draw_shadow` exists; GOP has no equivalent, callers just know) |
| Scene graph | ✅ step C — `toolkit/render/scene.tr` + `execute_software()` |
| SDL_GPU / WebGPU | ⛔ deferred — measured as unjustified, see §5a |

So the "Extreme Renderer" half of the diagram is **done and proven**. What v4 really
proposes is: (a) an IR between layout and paint, (b) a second, GPU-capable renderer,
and (c) four genuinely new core features.

---

## 3. The scene graph

`Interpreter.paint` currently walks the `LayoutBox` tree and calls
`fill_rect`/`set_pixel` as it goes. v4 splits that in two:

```
UiNode tree ──layout──> LayoutBox tree ──emit──> SceneGraph ──execute──> Renderer
```

A `SceneGraph` is a flat list of paint commands with everything already resolved:

```
Cmd.Rect(x, y, w, h, radius, fill, border_w, border, ambient)
Cmd.Circle(cx, cy, r, ring_w, fill, ring, ambient)
Cmd.Text(x, y, str, fg, ambient)
Cmd.PushClip(rect) / Cmd.PopClip
```

Three things this buys, all of which are current pain:

1. **A GPU renderer becomes possible at all.** You cannot batch or upload
   `set_pixel` calls. You can batch a list of rounded rects.
2. **Diffing** (v3 phase 6) becomes tractable — compare two flat command lists
   rather than two paint traversals.
3. **Sub-rect rendering** (the `render_to()` limitation that forced the
   host-paints-the-dynamic-part workaround in every widget demo) becomes a
   translation applied to a command list.

The cost is one more allocation per frame — which the phase-1 arena already handles,
and which is the same shape as the `LayoutBox` tree that is already rebuilt per frame.

**Open question:** does the software rasterizer execute the scene graph, or does the
scene graph replace the rasterizer's inputs? Cheapest path: `execute_software(scene,
canvas)` keeps every existing `Canvas` backend working unchanged, and the scene graph
becomes an internal detail rather than a breaking change. Recommended. **✅ This is
what shipped — see §3a; no backend was touched and the hosted renders came out
byte-identical.**

---


---

## 3a. Steps C and D — delivered 2026-09-07

**C: the scene graph.** `Interpreter.paint()` became `Interpreter.emit()`, producing a
flat `Scene` of commands, and a separate `execute_software(scene, canvas, font)` replays
them. Shipped as:

```
toolkit/render/scene.tr   Cmd (tagged: rounded_rect | rounded_box | text), Scene
toolkit/ui/interp.tr      emit(), build_scene(), execute_software()
```

Verified the strongest way available: **the three hosted PPMs are byte-identical to the
pre-refactor renders.** All five tiers rechecked — hosted byte-identical, 81/81 token
assertions, desktop compiles, web headless-verified in node (arena steady, correct
colours, 540000/540000 pixels painted), bare metal on Cortex-M3 with the arena still
flat across four frames, UEFI screenshot unchanged.

**No `Canvas` backend was touched.** That was the design goal from §3's open question,
and the answer it recommended turned out to be right: the commands bottom out in exactly
the primitives the five backends already supported, so the scene graph is an internal
detail rather than a change to the boundary the portability claim rests on.

Cost: ~1.6 KB per frame on the bare-metal demo (arena 104856 → 106472 bytes), all of it
reclaimed by the phase-1 per-frame reset.

Two design notes, both recorded in `scene.tr`:

- **It imports nothing.** `interp.tr` owns emitter and executor because the primitives
  live there; if `scene.tr` called them it would import `interp`, which imports `scene`,
  and Tauraro rejects cycles.
- **A tagged class, not an enum.** `toolkit/ui/ast.tr` uses a real enum with `Pointer`
  boxing because a UI tree is recursive and its variants differ structurally. A command
  list is flat and its variants differ only in *which fields matter*, so one tagged class
  costs an allocation instead of an allocation plus a box, and needs no match arm to read
  a field. The unused fields are the price.

**D: sub-rect rendering — and a correction to §3.**

§3 said translating a finished command list would be the mechanism for sub-rect
rendering. **That was wrong**, and `Scene.translate()` has been deleted rather than left
as dead code.

`place()` has always taken an origin — `layout_tree` simply passed `(0, 0)`. So the whole
feature is `layout_tree_at(node, cache, x, y, w, h)`, with no translation anywhere.
Translating a finished scene would also have been *incorrect*, not merely redundant:
hit-testing walks the same tree the painter does, so boxes must carry absolute
coordinates or `dispatch()` tests a different space than it paints.

`render_into(it, tree, canvas, x, y, w, h, ambient)` is the public entry point — a free
function for the same reason `render_to` is, since a method call does not auto-upcast a
concrete backend to the `Canvas` interface.

**The workaround it existed for is gone.** `examples/widgets_demo`'s tab content is now
real markup rendered into its slot, replacing ~20 lines of host-painted primitives and
the comment explaining why they were necessary.

One sharp edge, documented at both the API and the call site: `render_rect` replaces
`root`, so a caller compositing several regions and wanting clicks on all of them needs
**one Interpreter per region**. The demo uses a second one for tab content; sharing the
page's would have silently pointed OK/CANCEL at the tab tree, because the event drain
hit-tests whatever root the previous frame left behind.

The move also exposed a latent blending bug: the host-painted version passed the *canvas
clear colour* as its antialiasing backdrop, blending every rounded corner toward a colour
nothing had painted, since the chrome's `bg-slate-800` root covers the window.

Regression test: `verified-examples/subrect_render.tr`, 10 assertions covering the two
properties a screenshot cannot show — that previously painted chrome **survives** a
sub-rect render, and that the resulting boxes carry absolute coordinates.
## 4. Capability flags

The sketch's best small idea, because the problem is already real: `draw_shadow`
exists on `SdlCanvas` and not on `GopCanvas`, and today the *caller* is expected to
know that. `examples/uefi_demo/render_widgets.tr` documents "no drop shadow" in a
comment.

```
pub class Caps:
    pub alpha_blend:  bool   # can composite; GOP framebuffer cannot
    pub shadows:      bool
    pub gpu:          bool
    pub read_back:    bool   # can sample the destination
    pub subpixel_text: bool
```

Rule: **the baseline is guaranteed, enhancements are opt-in and degrade silently.**
A shadow on a renderer without `shadows` is skipped, not emulated badly and not an
error. That is exactly how the toolkit already treats unknown style tokens, so it is
a consistent rule rather than a new one.

---

## 5. The Modern Renderer

SDL_GPU (desktop, mobile, TV) and WebGPU (browser v2). This is the genuinely new,
genuinely large piece, and it is worth being blunt about what it costs:

- Every shape needs a shader path. The current AA is 16 integer subsamples per pixel
  computed in Tauraro (`RASTERIZER.md` §5); on a GPU that becomes an SDF fragment
  shader, which is a *different implementation of the same maths* that must agree
  with the software one or the tiers stop being pixel-identical.
- "Pixel-identical across tiers" is this project's strongest verified claim. A GPU
  renderer **will** break it at the sub-pixel level. That is acceptable, but the
  claim has to be restated honestly: identical on the software tiers, visually
  equivalent on the GPU tier.
- SDL_GPU is a 2024+ API. Availability in the bundled SDL2 needs checking before any
  of this is designed — `toolkit/render/desktop/sdl_bindings.tr` is generated from
  SDL2 headers, and SDL_GPU shipped in SDL3.

**That last point is a gating unknown and should be probed first**, exactly the way
phase 3's directory/process question was: it may be that "Modern Renderer" means
SDL3, which is a dependency change, not a rendering change.

---

---

## 5a. Step A result — measured, 2026-09-07

**Answer: "Modern Renderer" is a dependency change (SDL3), and it is not
justified by performance on any target we have.**

Evidence, from `bench_render.tr` (kept in the repo; rebuild and rerun to re-check):

```
renderer flags   : 10   -> accelerated: true, target texture: true
max texture      : 8192x8192

1600x1000, 60 frames, a card with 4 rounded panels, 2 buttons and 3 text runs:

A  per-pixel SDL calls      : 4.57 ms/frame   (219 fps)
B  RAM + streaming texture  : 8.08 ms/frame   (124 fps)
C  rasterize only, no upload: 2.20 ms/frame
```

Four things follow, and two of them were surprises:

1. **SDL_GPU is not available to us.** `toolkit/render/desktop/sdl_bindings.tr` has
   838 bound symbols and **zero** `SDL_GPU*`: it is generated from SDL2 headers, and
   SDL_GPU shipped in SDL3. Adopting it means a new DLL, regenerated bindings, and
   an API migration (`SDL_Renderer` changed, `SDL_Rect` became `SDL_FRect`, the event
   union changed) — a dependency project, not a rendering one.

2. **We are already on the GPU.** The SDL2 renderer reports `ACCELERATED |
   TARGETTEXTURE`. The `fill_rect` path has been hardware-accelerated all along.

3. **The streaming texture is 1.8x SLOWER, not faster.** This was the expected
   "modern" win and it is a loss: a full-frame upload is 1600·1000·4 = 6.4 MB across
   PCIe every frame, whereas per-pixel draws only touch pixels actually painted —
   and SDL2 batches those internally into vertex buffers (2.0.10+).

4. **Rasterization is only 48% of the cost.** Path A splits roughly evenly between
   the Tauraro rasterizer (2.20 ms) and SDL submission (2.37 ms). So even a perfect
   GPU renderer — zero submission, AA in shaders — is bounded by removing ~4.5
   ms/frame from something already running at 219 fps.

**What this reorders.** The thing that would actually help is **diffing**: repaint
only what changed, instead of re-rendering a static scene from scratch 60 times a
second. That needs the scene graph (step C), costs no new dependency, and helps
*every* tier — including UEFI and bare metal, which have no GPU to fall back on and
where the frame cost is measured in hundreds of milliseconds, not single digits.

A GPU renderer helps only the tiers that are already fast.

**Recommendation:** move step H (Modern Renderer) out of the near-term plan and treat
it as an opt-in upgrade to be revisited if a workload appears that the software path
cannot serve — very large surfaces, real-time animation across a full screen, or a
mobile target where power, not throughput, is the constraint. Nothing we have today
qualifies.

## 6. The four new core features

**Widget tree + state management.** The biggest gap, and the one that most limits
what can be built. Today `Interpreter.render()` rebuilds every `LayoutBox` from a
*static* class string, so anything stateful (checked, dragging, scroll offset) lives
in a host-owned object outside the markup — see `toolkit/ui/textinput.tr`'s header.
That is why `render_live.tr` keeps five scalars and rebuilds its widgets every frame.
Real state means the AST gains identity: a node needs a stable key across frames so
its state can be found again.

**Animation + transitions.** Needs a frame clock and interpolated properties. Cheap
once state exists, near-impossible before — `Switch.tick()` is what hand-rolling it
looks like.

**Grid layout.** Additive next to flex; `toolkit/layout/` gains a second algorithm.
Lowest risk of the four.

**Theme + design tokens.** Mostly indirection over the existing palette: a token
table resolved at style time so `bg-surface` means something a theme can change.

---

## 7. `.nbl` vs `.ui`

The sketch says `.nbl`. Purely cosmetic, but decide once and early — it touches every
example, both build scripts, `cli/config.tr`'s default, and every doc. Doing it later
costs strictly more than doing it now. No technical argument either way; `.nbl` is
more distinctive and less likely to collide with other tooling.

---

## 8. Sequencing

Doing this as one change would break four working tiers at once. Proposed order, each
step shippable and leaving the repo green:

| | Step | Risk | Unblocks |
|---|---|---|---|
| ~~A~~ | ~~Probe SDL_GPU/SDL3~~ ✅ **done** | none | answered: dependency change, and not justified — see §5a |
| ~~B~~ | ~~`Caps` flags, wired to existing backends~~ ✅ **done 2026-09-08** | low | honest shadow/alpha handling; no behaviour change |
| ~~C~~ | ~~Scene graph + `execute_software()`~~ ✅ **done 2026-09-07** | medium | shipped; hosted PPMs byte-identical, all five tiers green |
| ~~D~~ | ~~Sub-rect rendering~~ ✅ **done 2026-09-07** | low | shipped; `render_into()`, and the workaround is deleted from widgets_demo |
| ~~E~~ | ~~Grid layout~~ ✅ **done 2026-09-08** | low | shipped; `measure_grid`/`place_grid` in toolkit/layout/flex.tr, verified grid_layout.tr |
| ~~F~~ | ~~Node identity + state management~~ ✅ **done 2026-09-08** | high | shipped; `LayoutBox.node_key` (toolkit/layout/flex.tr build()) + `Interpreter.state` (toolkit/ui/interp.tr), verified node_identity.tr. Found+documented a real compiler gap along the way (bugs.txt #11: class str-field reads aren't retained) — worked around in nebula, not fixed in the compiler this session |
| ~~G~~ | ~~Animation + transitions~~ ✅ **done 2026-09-08** | medium | shipped; `Interpreter.anim_toward` (generalizes Switch.tick()), wired into emit()'s hover/press darken, verified animation.tr |
| ~~H~~ | Modern Renderer (SDL_GPU / WebGPU) — **deferred**, see §5a | high | nothing we have needs it |
| ~~I~~ | ~~Diffing on the scene graph~~ ✅ **done 2026-09-07** | medium | shipped; `execute_diff`/`render_diff_to`, verified diff_render.tr — not yet wired into any real frame loop (see nebula1.0.md §6, Phase 1) |

**All of A–G and I are done; H remains deliberately deferred (§5a) and nothing
measured since has changed that conclusion.** See nebula1.0.md §6 for the fuller
status cross-check against that document's own Phase 1–4 list, including what's
NOT done and why each of those gaps was left open rather than attempted.

---

## 9. What I would push back on

- **`Renderer` raises the cost of a new platform.** Today it is four methods with no
  alpha and no read-back — which is precisely why it works on a write-only firmware
  framebuffer. Keep a `Canvas`-shaped software path as the floor so "runs on a
  Cortex-M" stays true, and let `Renderer` be the richer interface above it.
- **Pixel-identical is a claim worth protecting.** It has caught at least one real
  regression. Before adding a GPU renderer, decide what replaces it as the
  cross-tier check.
- **State management (F) is the highest-value item in the sketch and the one most
  likely to be underestimated.** It changes the AST contract, not just a backend.
  Worth its own proposal.
