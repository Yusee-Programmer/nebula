# Nebula — proposal v3: a cross-platform GUI engine

**Status:** current. Supersedes `proposal-v2-runtime-interpreter.md`, which framed this
project as a bare-metal UI toolkit with a dev loop attached. That framing was too narrow.
**Written 2026-09-06.**

---

## 1. What Nebula is

**Nebula is a cross-platform GUI engine with its own declarative UI syntax, written in
Tauraro. Write once, run anywhere: browser, desktop, mobile, embedded, bare metal, UEFI —
up to and including an operating system's own interface.**

That last one is not a stretch goal bolted onto a desktop toolkit. It is the constraint the
whole design was built against, and it is why the rest of the list is reachable: an engine
that can paint a login screen on firmware with no OS, no libc, no filesystem, no allocator
and no window manager has already given up every dependency that normally makes a GUI
framework non-portable.

Most GUI frameworks are portable *downward* from a desktop OS — they assume threads, a
compositor, a font service, an allocator, and a graphics API, then work to shed them.
Nebula was built the other way, from nothing upward, so each new platform *adds* capability
instead of requiring the engine to give something up.

### 1.1 The portability claim, stated precisely

> Everything above the pixel is platform-agnostic. A new platform costs one `Canvas`
> implementation and one input source.

`Canvas` is four methods:

```
width() -> int          height() -> int
fill_rect(x, y, w, h, color)
set_pixel(x, y, color)
```

No alpha. No destination read-back. No state. No graphics API. That interface is the entire
contract between Nebula and the machine it is running on, and it is deliberately small
enough that a write-only memory-mapped framebuffer satisfies it completely.

Everything else — markup parser, style resolution, flexbox layout, the tree-walking
interpreter, the antialiasing rasterizer, the baked font, hit-testing, event dispatch, and
all nine widgets — is ordinary Tauraro that never learns which platform it is on.

**This is not aspirational.** The same toolkit source is running today on four backends
that share no code below `Canvas`, and the UEFI and desktop renders are pixel-identical.

### 1.2 What "run anywhere" rests on

`tauraroc --target` already cross-compiles to every platform in the vision:

| Family | Targets the compiler already accepts |
|---|---|
| Browser | `wasm`, `wasm-wasi` |
| Mobile | `android-arm64`, `android-arm32`, `android-x86_64`, `android-x86`, `ios`, `ios-sim` |
| Desktop | `windows-x64`, `windows-arm64`, `macos-arm64`, `macos-x86_64`, `linux-x86_64`, `linux-arm64` |
| Embedded | `embedded-arm`, `embedded-arm64`, `embedded-riscv32`, `embedded-riscv64` |
| Firmware | `uefi-x64` (turnkey `.efi`) |

**So reaching the browser and mobile is a backend problem, not a compiler problem.** That is
the single most important fact in this document, because it means the remaining work is
bounded and known in shape: write a `Canvas`, wire an input source, done.

---

## 2. Where the project actually is (2026-09-06)

Everything in this section is verified by compiling and running, not by reading code.

### 2.1 The shared core — done

| Module | What it does |
|---|---|
| `toolkit/types.tr` | color packing, `Rect`, `Event`, `EventHandler` (imports nothing) |
| `toolkit/ui/ast.tr` | `UiNode` enum, boxing, depth guard |
| `toolkit/ui/parser.tr` | XML-like markup → `UiNode`; never fatal on malformed input |
| `toolkit/ui/palette.tr` | GENERATED — 22 hues × 11 shades |
| `toolkit/ui/scale.tr` | Tailwind token suffix → pixels |
| `toolkit/ui/style.tr` | utility token table, `Style`, `StyleCache` |
| `toolkit/layout/flex.tr` | build / measure / place; row+col, per-side padding, margins, gap, grow, fractions, justify, items |
| `toolkit/ui/interp.tr` | tree walk, AA rasterizer, glyph painting, hit-test, dispatch |
| `toolkit/text/` | baked antialiased glyph atlas (GENERATED) + lookup |
| `toolkit/ui/*.tr` | nine host-owned widgets |

### 2.2 The four live backends

| Backend | Canvas | Input | Status |
|---|---|---|---|
| Hosted | `BufferCanvas` → PPM | synthetic | ✅ the dev loop |
| Desktop | `SdlCanvas` (SDL2) | real mouse + keyboard + wheel | ✅ live window, DPI-aware |
| UEFI | `GopCanvas` (GOP framebuffer) | **none yet** | ✅ renders, static frame |
| Bare metal | `FrameBuffer` (MMIO → UART) | **none yet** | ✅ Cortex-M3 under qemu |

The desktop and UEFI tiers render the full nine-widget panel **pixel-identically**. The
only difference in the source is which `Canvas` is constructed.

### 2.3 Proven properties worth not re-litigating

- **Antialiasing needs no alpha channel.** 4×4 integer supersampling computes the blended
  color *before* `set_pixel`, against a caller-supplied backdrop. This is why a write-only
  firmware framebuffer looks identical to an SDL2 window. See `RASTERIZER.md`.
- **The markup grammar is tag-agnostic.** `<button>` is a `<panel>` by convention; new tags
  cost nothing. Only `<text>` is special.
- **Class strings are real Tailwind.** `p-4` is 16px. Full palette, arbitrary values
  (`w-[460px]`), exact fractions (`w-1/3` fills a row with no rounding gap).
- **Styles are cached per unique class string**, so runtime resolution costs once, not
  once per node per frame.
- **Layouts compose into one tree.** This matters later: it is why a page-inside-a-layout
  needs no viewport support.

### 2.4 Known gaps, ranked by how much they block the vision

1. **No input on UEFI or bare metal.** Everything downstream of an event exists and is
   proven on two other tiers. What is missing is upstream: a protocol/driver read that
   produces `Event.click` / `Event.key`. This is the single blocker on OS-level UI.
2. **The freestanding allocator never frees.** Bump-only, so those tiers are strictly
   single-frame today. Blocks animation, redraw, and anything data-driven.
3. **One font size.** A single baked 8×14 atlas. `text-lg` parses and does nothing.
4. **No browser or mobile backend.** Nothing blocks them; nobody has written them.
5. **No CLI.** Every tier is driven by a bespoke PowerShell script, and the ~80-line bump
   allocator is copy-pasted into four programs.
6. **No app structure.** No routing, no navigation, no project scaffold. You write a
   `main.tr` per app and wire everything by hand.
7. **`render_to()` cannot paint into a sub-rect** — the root always fills the canvas.
8. **No diffing.** Re-render repaints everything.

---

## 3. Architecture: the three layers

```
                 ┌─────────────────────────────────────────────┐
   YOUR APP      │  .ui markup   +   .tr handlers   +  config   │
                 └─────────────────────────────────────────────┘
                                      │
                 ┌─────────────────────────────────────────────┐
   ENGINE        │  parser → style → layout → interpreter      │
   (portable,    │  rasterizer · font · widgets · hit-test     │
    one copy)    │  ── knows nothing about any platform ──     │
                 └─────────────────────────────────────────────┘
                                      │
                          Canvas  +  input source
                                      │
      ┌────────┬────────┬────────┬────────┬────────┬──────────┐
      │ Buffer │  SDL2  │  GOP   │  MMIO  │  wasm  │  mobile  │
      │ hosted │desktop │  UEFI  │  bare  │browser │ android/ │
      │        │        │        │        │        │   ios    │
      └────────┴────────┴────────┴────────┴────────┴──────────┘
         done     done     done     done     TODO      TODO
```

**The engine layer is the product.** Backends are small and boring by design — the SDL2
one is ~200 lines of forwarding, the GOP one is thinner than that. Keeping them boring is
what keeps the promise honest.

### 3.1 Adding a platform: the actual checklist

1. Implement `Canvas` (4 methods) over whatever the platform gives you for pixels.
2. Produce `Event.click(x,y)` / `Event.key(code)` from whatever it gives you for input.
3. Provide `@allocator`/`@free`/`@realloc`/`@calloc` if freestanding.
4. Call `render_to(it, tree, canvas)`.

There is no step 5. No shader, no layout engine port, no font stack, no theme system.

### 3.2 What each remaining platform needs

| Platform | Canvas over | Input from | Notes |
|---|---|---|---|
| **Browser** | WASM linear memory → `ImageData` blitted to `<canvas>` | DOM events into an exported fn | Needs JS interop shape verified; the memory-buffer approach means the *rasterizer* is unchanged |
| **Android** | SDL2 (already bound) or `ANativeWindow` | SDL2 or `AInputEvent` | SDL2 path is likely near-free — same `SdlCanvas` |
| **iOS** | SDL2 or `CAMetalLayer` drawable | UIKit touches | Same |
| **OS interface** | whatever the kernel exposes | the kernel's own drivers | This is the UEFI/bare-metal case with a different owner |

Android and iOS are the cheapest of these by a wide margin, because `SdlCanvas` already
exists and SDL2 supports both — plausibly a build-configuration exercise rather than new
rendering code.

---

## 4. The developer experience we are building toward

```
nebula init my-app
nebula dev                 # hosted + watch, fastest loop
nebula run --desktop
nebula run --web
nebula run --android
nebula run --uefi
nebula build --uefi -o dist
```

You write `.ui` files and `.tr` handlers. You never invoke `tauraroc`, never write a bump
allocator, never write an event loop, never learn a linker flag.

### 4.1 Project shape

```
my-app/
  nebula.conf              app name, window size, default route, target list
  app/
    layout.ui              wraps every screen
    page.ui                "/"
    page.tr                handlers for "/"
    settings/
      page.ui              "/settings"
      page.tr
  components/
    card.ui                reusable partials
  .nebula/                 generated, gitignored
```

### 4.2 The one architectural decision this rests on

**Folder-based screen routing must be resolved at BUILD time, not runtime.**

UEFI, bare metal and embedded have no filesystem. Today's demos handle that by pasting
markup into a string literal by hand. So `nebula build` walks `app/`, and generates a
Tauraro source file containing every screen's markup as string constants, plus a screen
table and the handler registrations.

Hosted and desktop then get a second, *optional* path: read the same files from disk, which
is what makes hot reload possible. Same screen table either way.

```
app/**/page.ui ──┬─ build-time codegen → .nebula/generated.tr → every platform
                 └─ runtime disk read ─────────────────────────→ dev only
```

This is what makes "just write `.ui` files" true on a firmware framebuffer, and it is the
difference between a design that works on one platform and one that works on all of them.

### 4.3 Navigation costs no grammar change

`@on_click(goto:/settings)` — the AST already stores the handler as an opaque string.
Codegen sees the `goto:` prefix, emits one handler class per distinct target, and registers
it. Parser, AST and interpreter are untouched. A small runtime `Router` holds the current
screen and a back stack.

**Terminology note:** this is a *screen stack*, not routing. There is no URL bar, no
history API, no deep linking, no query params. Borrowing the folder convention from Next.js
is good ergonomics; borrowing the word "routing" would import expectations that will never
be met.

### 4.4 Templating

Deferred. **`templa`** — the project's own template engine — is the intended mechanism, to
be integrated later. Jinja was considered and rejected: Nebula is meant to be a
self-contained stack with its own syntax.

What this proposal commits to now is only that the *expansion step* is a distinct build
phase with a pluggable engine, so `templa` drops into a defined slot rather than being
retrofitted. Layout/partial composition (§4.1's `layout.ui` and `components/`) is
deliberately specified as **structural**, not template-language-dependent, so it can ship
before `templa` does.

---

## 5. Plan

Ordered by value delivered per unit of risk, not by dependency convenience. Each phase is
independently shippable and leaves the repo working.

### Phase 1 — Unblock the freestanding tiers *(highest value)*

Two changes turn UEFI and bare metal from "renders a picture" into "runs an interface", and
they are the difference between a rendering demo and a GUI engine.

- **1a. Per-frame arena reset.** Bump allocator gains a mark/release so a frame's
  allocations are reclaimed wholesale. Unblocks animation, redraw, and every data-driven
  feature on three of the six platform families.
- **1b. A UEFI input driver.** Simple Pointer + Simple Text Input → `Event`. Everything
  downstream already exists and is proven on desktop. **This produces the login screen.**

*Exit:* `examples/uefi_demo` responds to a mouse and a keyboard, redrawing every frame.

### Phase 2 — The browser backend

The single biggest widening of reach, and it validates the portability claim against a
platform maximally unlike the ones already working.

- WASM `Canvas` writing into linear memory; JS blits to `<canvas>` via `ImageData`.
- DOM events → an exported Tauraro entry point.
- Verify the JS interop shape first with a compiling probe — this is the main unknown.

*Exit:* `examples/widgets_demo` running in a browser tab, pixel-comparable to desktop.

### Phase 3 — The `nebula` CLI

- `init`, `dev`, `run --<target>`, `build`.
- Generates the tier entry point, including the bump allocator now copy-pasted four times.
- Absorbs the four PowerShell scripts and their flag folklore.
- **Settle the CLI's implementation language first** (see §6).

*Exit:* every existing demo builds and runs through `nebula`, no scripts invoked directly.

### Phase 4 — App structure

- Folder-based screens, build-time codegen, `layout.ui` composition.
- `goto:` navigation + `Router`.
- Hot reload on `nebula dev`.

*Exit:* a two-screen app with navigation, written without touching a `.tr` entry point.

### Phase 5 — Mobile

- Android and iOS via the existing `SdlCanvas`; likely mostly build configuration.

*Exit:* `widgets_demo` on a phone.

### Phase 6 — Engine depth

Ordered within the phase by demand:

- **Multiple font sizes** (a second baked atlas + `text-*` size tokens). Currently the most
  visible authoring limitation.
- **Gamma-correct blending** (`RASTERIZER.md` §3).
- **Sub-rect rendering** — removes the whole host-paint-the-dynamic-part workaround class.
- **Diffing** — repaint only what changed.
- **`templa` integration.**
- Images/assets, per-corner radii, shadows on non-alpha backends.

---

## 6. Open questions and risks

Stated plainly, because each one can change a phase's shape.

| # | Question | Why it matters | How to settle it |
|---|---|---|---|
| 1 | Can Tauraro list directories and spawn processes? | Decides whether `nebula` is a Tauraro binary or a Tauraro core + shell wrapper. Blocks Phase 3's shape. | A 20-line compiling probe. Do this before designing the CLI. |
| 2 | What does WASM interop look like — can Tauraro export functions to JS and import from it? | Blocks Phase 2 entirely. | Compiling probe against `--target wasm`. |
| 3 | Does SDL2 actually build for `android-arm64` / `ios` through `tauraroc`? | Decides whether Phase 5 is days or weeks. | Try the cross-build early; it is cheap to test. |
| 4 | Is `--no-heap` viable for the smallest embedded targets? | The engine currently uses `List`/`Dict` throughout, so probably not without a parallel data path. Affects how far "embedded" reaches. | Compile the toolkit with `--no-heap` and read the errors. |
| 5 | What is `templa`'s syntax and integration surface? | Shapes the expansion phase's interface. | Ask, before building the slot. |

### Risks worth naming

- **Backend sprawl.** Six platform families is a lot of surface for one person. The
  mitigation is structural and already in place: backends stay tiny because `Canvas` is
  four methods. **If a backend starts growing engine-shaped code, that is the signal
  something belongs in the core instead.**
- **Per-platform verification cost.** "Pixel-identical across tiers" is the project's
  strongest claim and it only stays true if it is checked. Byte-diffing hosted PPMs already
  caught a regression this way; that should become the standard check for every backend.
- **The `__chkstk` class of bug.** Some failures appear on exactly one platform, long after
  the code looks correct everywhere else (see CLAUDE.md). Expect more of these as platforms
  are added, and build each one green before moving on.
- **Scope discipline.** Phases 1 and 2 deliver most of the vision's credibility. Phases 3–4
  are ergonomics on top of a working engine, and are easy to start too early.

---

## 7. What "done" looks like

The same `app/` directory — unmodified — produces:

- a browser tab,
- a desktop window on Windows, macOS and Linux,
- an Android and an iOS app,
- a `.efi` that boots to an interactive screen on real firmware,
- a Cortex-M image driving a panel over MMIO,

with identical layout and pixel output everywhere the display allows it, and with the only
per-platform code in the repo being a four-method `Canvas` and an input source per family.

Four of those six already render. None of the remaining work requires the engine to learn
what platform it is on.
