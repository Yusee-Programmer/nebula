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
| Scene graph | ❌ the interpreter paints immediately during its tree walk |
| SDL_GPU / WebGPU | ❌ not started |

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
becomes an internal detail rather than a breaking change. Recommended.

---

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
| **A** | Probe SDL_GPU/SDL3 availability | none | decides whether §5 is a rendering change or a dependency change |
| **B** | `Caps` flags, wired to existing backends | low | honest shadow/alpha handling; no behaviour change |
| **C** | Scene graph + `execute_software()` | medium | every `Canvas` backend keeps working; diffing and sub-rect become possible |
| **D** | Sub-rect rendering via the scene graph | low | deletes the host-paint-the-dynamic-part workaround class |
| **E** | Grid layout | low | additive |
| **F** | Node identity + state management | high | animation, real widgets in markup |
| **G** | Animation + transitions | medium | needs F |
| **H** | Modern Renderer (SDL_GPU / WebGPU) | high | needs A, B, C |

**Recommended start: A → B → C → D.** That order gets the IR in place, keeps every
tier green, and pays off immediately (D removes a workaround that currently infects
every widget demo) without committing to the GPU work until A has told us what it
actually involves.

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
