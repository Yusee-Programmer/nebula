# Nebula

**A cross-platform GUI engine with its own declarative UI syntax, written in
[Tauraro](https://github.com/tauraro/tauraro).**

Write once, run anywhere: **browser, desktop, mobile, embedded, bare metal, UEFI** — up to
and including an operating system's own interface.

```
<panel "flex-col p-6 gap-4 bg-slate-900">
  <text "text-slate-100">NEBULA</text>
  <panel "flex-row gap-4 grow">
    <panel "w-1/2 bg-indigo-500 rounded-xl" />
    <panel "grow bg-emerald-500 rounded-xl" />
  </panel>
  <button "grow bg-sky-500 rounded-lg justify-center items-center" @on_click(on_save)>
    <text "text-white">SAVE</text>
  </button>
</panel>
```

That file renders identically in an SDL2 window, into a UEFI firmware framebuffer with no OS,
and on a Cortex-M3 with no libc and no filesystem.

## Why it ports so widely

Most GUI frameworks are portable *downward* from a desktop OS — they assume threads, a
compositor, a font service, an allocator and a graphics API, then work to shed them. Nebula
was built the other way, from nothing upward. The entire contract between the engine and the
machine is four methods:

```
width() -> int          height() -> int
fill_rect(x, y, w, h, color)
set_pixel(x, y, color)
```

No alpha. No destination read-back. No state. No graphics API. A write-only memory-mapped
framebuffer satisfies it completely — which is why antialiasing had to be solved by computing
the blended color *before* the pixel write (4×4 integer supersampling against a known
backdrop), and why the result looks identical on every backend.

**Adding a platform costs one `Canvas` implementation and one input source.** Everything above
the pixel — markup parser, Tailwind-style resolution, flexbox layout, tree-walking
interpreter, rasterizer, baked font, hit-testing, event dispatch, and all nine widgets — never
learns which platform it is on.

## Status

| Backend | Canvas | Input | State |
|---|---|---|---|
| Hosted (PPM) | `BufferCanvas` | synthetic | ✅ the dev loop |
| Desktop (SDL2) | `SdlCanvas` | mouse, keyboard, wheel | ✅ live window, DPI-aware |
| UEFI (GOP) | `GopCanvas` | **mouse + keyboard** | ✅ **live interactive loop** |
| Bare metal (MMIO) | `FrameBuffer` | — | ✅ Cortex-M3, multi-frame |
| Browser (WASM) | `WebCanvas` | mouse + keyboard | ✅ **runs in a tab** |
| Mobile (Android/iOS) | — | — | planned |

The desktop and UEFI tiers render the full nine-widget panel **pixel-identically**; the only
difference in the source is which `Canvas` is constructed.

Reaching mobile is *backend* work, not compiler work — `tauraroc --target`
already cross-compiles to `wasm`, `wasm-wasi`, `android-*`, `ios`, `macos-*`, `linux-*`,
`windows-*`, `embedded-*` and `uefi-x64`.

## Quick start

### With the `nebula` CLI (recommended)

```sh
tauraroc cli/nebula.tr -o nebula.exe    # build the CLI once

nebula init my-app
cd my-app
nebula run --hosted     # fastest loop: renders a PPM
nebula run --desktop    # a real window
nebula run --web        # a wasm module + host page
```

An app is `app/page.ui` (the UI, as data) plus `app/page.tr` (handlers, via
`register_all(it)`). The CLI generates every tier's entry point -- including the bump
allocator the freestanding targets need -- so none of that is yours to write. `--uefi`
and `--bare` work too, but still delegate to `scripts/` for their linker script, zig
stub and qemu invocation.

### Directly, against the repo

Run everything from the repository root, so `toolkit.*` module paths resolve.

```sh
# browser — WASM in a tab
./scripts/build-web.ps1
python3 -m http.server 8000 --directory build-web   # then open localhost:8000

# hosted — fastest loop, writes a PPM
tauraroc --run examples/quickstart/main.tr

# desktop — a real window with live input
tauraroc examples/quickstart/desktop.tr -o build/quickstart.exe --link SDL2.lib
build/quickstart.exe

# UEFI — a real firmware framebuffer under QEMU
./scripts/build-uefi-turnkey.ps1 -Source examples/uefi_demo/render_widgets.tr -OutDir build-uefi-widgets
./scripts/run-uefi.ps1 -OutDir build-uefi-widgets -Build:$false
```

`examples/quickstart/` is the smallest complete program — the same `app.ui` rendered hosted
and in a window, so the diff between tiers is one line.

## The UI syntax

Angle-bracket markup, with a **bare quoted class string** — no `class="..."` — and
`@event(handler)` binding a handler *name*, so markup never references code directly.

Class strings are **real Tailwind**: numbers are scale steps, so `p-4` is 16px. The full
22-hue × 11-shade palette, arbitrary values (`w-[460px]`), and exact fractions (`w-1/3` fills
a row with no rounding gap). Tags are arbitrary — `<button>` is a `<panel>` by convention, and
only `<text>` is special.

Templating is **`templa`** (this project's own engine), integrated later.

## Repo layout

```
toolkit/ui/          markup AST, parser, interpreter, style, palette, scale, widgets
toolkit/layout/      flexbox subset
toolkit/render/      Canvas interface, scene graph, one directory per backend
toolkit/text/        baked antialiased glyph atlas + lookup
examples/quickstart/ the smallest complete program — start here
examples/            one demo per tier, plus the nine-widget showcase
cli/                 the `nebula` command: config, codegen, toolchain driver
docs/proposal/       the spec (v3 shipping, v4 in progress)
verified-examples/   .tr programs confirmed to compile and run, incl. token tests
scripts/             per-tier build/run, font baking, palette generation
RASTERIZER.md        the rasterizer spec — read before touching a shape primitive
bugs.txt             confirmed Tauraro defects, each with a minimal repro
CLAUDE.md            project memory: verified language facts, gotchas, plan
```

## Documentation

- **`docs/proposal/proposal-v3-cross-platform-engine.md`** — the current spec: what Nebula is,
  where it stands, and the phased plan. Start here.
- **`CLAUDE.md`** — project memory. Verified Tauraro language facts (several of which
  contradict the upstream docs), per-tier build folklore, and hard-won gotchas.
- **`docs/proposal/proposal-v4-renderer-architecture.md`** — the next architecture: scene
  graph, capability flags, two renderers. Steps A, C and D are done; A is a measured
  argument for *not* building a GPU renderer yet.
- **`RASTERIZER.md`** — how antialiasing works without an alpha channel, and how to add a
  shape primitive without breaking the portability guarantee.

## License

See `tools/fonts/` for the bundled JetBrains Mono license (SIL OFL 1.1).
