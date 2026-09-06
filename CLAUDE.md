# Project memory — read this first

**Nebula is a cross-platform GUI engine with its own declarative UI syntax, written in the
Tauraro language** (github.com/tauraro/tauraro), interpreted at runtime rather than compiled
in. The goal is **write once, run anywhere: browser, desktop, mobile, embedded, bare metal,
UEFI — up to and including an operating system's own interface.**

Full rationale, current status and the phased plan:
**`docs/proposal/proposal-v3-cross-platform-engine.md`** — read that before writing code, it
is the current spec. (`proposal-v2-runtime-interpreter.md` is superseded: it framed this as a
bare-metal toolkit with a dev loop attached, which turned out to be too narrow a reading of
what the architecture supports.)

**The load-bearing architectural claim:** everything above the pixel is platform-agnostic, and
a new platform costs exactly one `Canvas` implementation (four methods —
`width`/`height`/`fill_rect`/`set_pixel`, no alpha, no read-back) plus an input source. Parser,
style resolution, layout, interpreter, rasterizer, font and all nine widgets never learn which
platform they are on. This is verified, not aspirational: four backends sharing no code below
`Canvas` are running today, and the UEFI and desktop renders are pixel-identical.

**And it is reachable everywhere**, because `tauraroc --target` already cross-compiles to
`wasm`, `wasm-wasi`, `android-*`, `ios`, `macos-*`, `linux-*`, `windows-*`, `embedded-*` and
`uefi-x64`. Browser and mobile are *backend* work, not compiler work. Run `tauraroc --help` to
confirm the list.

**Templating: use `templa`** (the project's own engine), not Jinja — Jinja was proposed and
explicitly rejected on 2026-09-06. Integration is deferred; keep the expansion step pluggable.

Everything below is what prior sessions verified about the Tauraro
language by actually building its compiler and compiling test programs against it — not by
reading documentation alone. Treat facts marked **verified** as tested; everything else is from
docs/README and should be spot-checked before being relied on for anything load-bearing.

**`bugs.txt`** at the repo root is the running log of confirmed Tauraro compiler/SDK/docs
defects, each reduced to a minimal repro. Check it before spending time re-diagnosing a hang or
a confusing error — several of the entries there cost hours the first time.

## Getting a working compiler immediately

**Use the installed Windows SDK. It is on PATH and it works.**

```
%USERPROFILE%\.taupkg\bin\tauraroc-windows-x64\tauraroc.exe
```

(`C:\Users\HomePC\...` in earlier notes below was a DIFFERENT machine's path — never
hardcode it; `scripts/build-bare.ps1`/`build-uefi.ps1` now resolve it via `$env:USERPROFILE`.)

**Updated 2026-09-04: this SDK copy has been refreshed with a dev build carrying fixes for
several bugs this file documents below** (register-keyword interface-upcast loss, method-call
auto-upcast, `[F-3]` exhaustive-match false positive, the `_WIN32`/`TAURARO_KERNEL` runtime-header
gap, and — the big one — **calling a first-class function value under `--freestanding` no longer
hangs/crashes** (tau_bugs.txt #1's root cause: the closure-vs-plain-function dispatch tagged
pointer bit 0, which collides with ARM Thumb's own use of that bit; fixed by switching to a
`{fn,env}` struct with no pointer-bit dependency, verified on real Cortex-M3/Thumb under qemu).
This means `EventHandler`/`register_handler`/`render_to()` are no longer STRICTLY necessary
workarounds — they still work fine and don't need to be reverted, but `Dict[str, def(Event) ->
void]` (the proposal's original 5.5 design) should now also work bare-metal if you want to try it.
Treat every "hangs on --freestanding" / "register is a C keyword" / "-U_WIN32 workaround" note
below as **possibly stale** — spot-check against this compiler before assuming it still applies.

It ships `zig/` (so no system gcc/clang is needed), `std/`, `runtime/`, plus `src/` (the
self-hosted compiler in Tauraro) and `examples/` — both are the best available source of
*idiomatic, actually-compiling* Tauraro, and worth reading before guessing at syntax from docs.

**Always run it from the repository root**, so that `.` (search-path priority 1) resolves
`toolkit.*` module paths:
```sh
tauraroc --run examples/hosted_demo/main.tr
```
Note: a fresh terminal may need PATH refreshed from the registry; the entry is on the *user*
PATH, so a shell started before install won't see it.

> The vendored `vendor/tauraroc/` binary below is **superseded and unusable on this machine** —
> it is a Linux x86-64 ELF. Kept only for provenance. Everything in this file that was verified
> against it has since been re-verified against the Windows SDK above.

`vendor/tauraroc/tauraroc` is a working Linux x64 build of `tauraroc v0.0.8`, built from the
upstream repo's own committed `bootstrap/c/` portable-C seed with:
```sh
gcc -O2 -w -Ibootstrap/c -std=gnu11 -D_GNU_SOURCE -D_XOPEN_SOURCE=700 \
  bootstrap/c/main.c bootstrap/c/module_*.c bootstrap/c/include/core/*.c \
  -o tauraroc -lm -lpthread -lrt
```
**Verified working** — this exact binary compiled and ran every `.tr` file in
`verified-examples/`. It needs `runtime/tauraro_rt.h` to be reachable — the compiler searches
(in order) relative to the binary's own directory/parent/grandparent for `runtime/tauraro_rt.h`,
and also checks `./runtime/tauraro_rt.h` relative to the **current working directory**. The
simplest reliable pattern: run it from `vendor/tauraroc/` (which has `runtime/` right beside the
binary), e.g. `./vendor/tauraroc/tauraroc --run ../../some_file.tr`, or `cd vendor/tauraroc &&
./tauraroc --run /absolute/path/to/file.tr`.

Before trusting anything below on real work: **get the actual current release binary** from
https://github.com/tauraro/tauraro/releases (currently `v0.0.8`) or re-clone and rebuild — this
vendored binary is a snapshot from one session and the upstream project is pre-0.1 (breaking
changes are normal between releases per its own versioning policy,
`docs/tauraro-lang-reference/dev/00_versioning_policy.md`).

Self-hosting (compiling the real compiler, written in Tauraro itself, at `src/*.tr` in the
upstream repo) was attempted and **failed** in this session with a missing-symbol link error
(`undefined reference to _tr_llvm_emit_object`) — not investigated further. Not needed for this
project; noted so it isn't re-discovered from scratch.

## Verified language facts (compiled and run, not assumed)

- **Collections: it's `Dict[K, V]`, not `Map[K, V]`.** `Dict` is the real user-facing type,
  constructed with a `{}` literal (`mut cache: Dict[str, int] = {}`), used with `in` and `[key]`
  indexing. An earlier draft of this project's proposal used `Map[...]` — that was wrong; ignore
  any `Map[...]` you see in older notes and use `Dict[...]`. See
  `verified-examples/dict_backed_cache.tr` for a confirmed-working example (a style-cache-shaped
  class using `Dict`).
- **Raw pointer `.read()` needs `unsafe:` in ordinary code.** `Pointer[T].read()` is rejected
  with error `[P-2]` outside an `unsafe:` block. The compiler's own internal modules (e.g.
  `src/mir.tr`) are exempt via a `@trusted` module annotation not available to ordinary user
  code — don't take patterns from the compiler's own source as proof something works unmarked.
- **`match` on an enum wants an explicit `case _:`, even when every variant is already listed**,
  or the compiler's return-path checker (`[F-3]`) reports a missing return on a function that in
  fact returns on every real path. Always add a trailing wildcard arm as a matter of style, even
  when it looks redundant. See `verified-examples/boxed_enum_tree_walk.tr` — a boxed recursive
  enum (`Pointer[UiNode]`) walked recursively with `match`, the exact pattern the UI AST design
  depends on, confirmed compiling and running correctly with this rule applied.
- **The macro system (`macro def` / `name!(...)`) segfaulted the compiler** on the simplest
  possible test case (a two-line function-like macro). Reproduced twice. Not yet retested against
  an actual release binary rather than this bootstrap build — do that before relying on macros
  for anything. The current proposal (v2) doesn't depend on macros for the UI/style system
  (that moved to a runtime interpreter instead), so this is lower-priority to chase down, but
  worth knowing before reaching for `macro def` for anything else.

## Verified while building the toolkit (compiled + run on the Windows SDK)

Everything here was confirmed by compiling and running it, not by reading docs. Several of these
contradict the docs directly — the docs lose.

**Ownership / moves — the biggest source of surprise.**
- **Assigning a local into a field moves it.** `self.root = box` then using `box` again is
  `[M-1]`. Assign first, then work through the field.
- **Upcasting to an interface-typed variable MOVES the concrete object.**
  `mut view: Canvas = canvas` makes `canvas` unusable afterwards — you can no longer call
  `canvas.save_ppm(...)`. This is a trap, because the docs present the explicit upcast as the
  recommended style.
- **Passing a concrete instance directly into a free function's interface parameter upcasts
  without moving it.** `draw(canvas)` where `def draw(c: Canvas)` leaves `canvas` fully usable.
- **A method call does NOT auto-upcast** — `it.render(tree, canvas)` fails to compile with an
  incompatible-pointer error. Combined with the two rules above, the working pattern is a free
  function wrapper; `toolkit/ui/interp.tr`'s `render_to()` exists solely for this reason.

**Interfaces.** `pub interface` in one module, `implements` in another, and vtable dispatch
across module boundaries all work. Two implementations of one interface confirmed working.

**Collections.**
- `Dict[str, def(Event) -> void]` **works hosted** — storing and fetching a function value from a
  Dict compiles and runs fine there. **But see `tau_bugs.txt` #1: calling any first-class function
  value hangs under `--freestanding`**, which rules this pattern out for the bare-metal tier
  despite compiling cleanly. The toolkit's handler bridge (`toolkit/ui/interp.tr`) uses an
  `EventHandler` interface instead, specifically because of this.
- `Dict[str, SomeClass]` works, as does `len(someDict)`.
- `List[T]` supports index assignment (`px[i] = v`) — the framebuffer depends on this.
- `List[u8]` works with explicit `255 as u8` casts.
- `len()` works on `List` and `Dict`. For a `str`, use `Str.len(s)`.

**Callables.** `def(int, int) -> int` **is** valid as a parameter type and as a class field type.
`docs/.../05_functions.md:477` explicitly calls this "ERROR: not valid syntax" — **that doc is
wrong**; the shipped `examples/28_first_class_functions.tr` uses it throughout. (`lambda` is the
type of *closures*, which are a different thing from top-level function values.)

**Standard library import paths: both forms work.** `from core.vec import Vec` and
`from std.hal.mmio import write32` are both valid, because the compiler's install root *and* its
`std/` subdirectory are both on the search path. The shipped examples use both. Prefer whichever
the nearest shipped example uses; don't "fix" one into the other.

Useful signatures, confirmed: `Str.len/split/slice(s,start,end_exclusive)/starts_with/index_of/
trim/char_at(->int codepoint)/parse_int/is_digit`; `StringBuilder.init(cap)/.append/.append_int/
.append_char(int)/.to_string().as_str()`; `File.read_text(path)->str`,
`File.write_text(path,data)->bool`.

**Syntax that works:** `elif`, `not`, `break` in nested `while`, private (non-`pub`) methods in an
`extend` block called via `self`, `for x in list`, integer division with `/`.

## Not yet verified — treat as docs-only until tested

Ownership/borrow annotations (`Own`/`Borrow`/`Move`/`Shared`) beyond their names; closure capture
semantics; interfaces/dynamic dispatch; `Result[T,E]`/`throws`/`?` error handling; concurrency
primitives (`spawn`, `Thread`, `Mutex`, `Chan` — note `Atomic[T]` is documented to work at every
runtime tier including freestanding, everything else concurrency-related is undocumented for
freestanding and likely OS-thread-backed only); and — most importantly for this project —
**nothing on the `--freestanding` / bare-metal path has been compiled yet.** That's the highest-
value thing to verify next; the proposal's whole premise rests on it.

## Known real gaps in Tauraro relevant to this project (confirmed absent, not just undocumented)

No framebuffer/graphics/rasterizer code anywhere in `std/` (searched the full tree). No font/text
rendering beyond a minimal `std/unicode`. No input drivers (PS/2, USB HID) of any kind. No
interrupt-controller support (PIC/APIC/GIC) — `@interrupt` only emits the bare GCC attribute, it
doesn't configure hardware. No filesystem or storage driver, which matters for the
`toolkit/transport/` layer's disk-based delivery option. No general-purpose allocator for the
freestanding tier — only a hand-written bump allocator is demonstrated
(`docs/tauraro-lang-reference/lang/advanced/11_bare_metal.md`). `std.gpu.Gpu` (the parallel-
dispatch story) is OpenMP-backed and hosted-only; not usable bare-metal. Full detail and the
reasoning behind each is in the proposal doc's §5–§8.

## Repo layout (from the proposal's §7, already scaffolded as empty dirs)

```
toolkit/ui/          UiNode AST, parser, tree-walking interpreter, style cache;
                        ALSO every real widget (textinput/checkbox/radio/switch/
                        slider/progress/dropdown/tabs/list) -- see below for why
                        this, not toolkit/widgets/, is where they actually live
toolkit/layout/       flexbox-subset layout engine
toolkit/render/       Canvas trait + rasterizer primitives
toolkit/render/hosted/  in-memory buffer backend (fast dev loop)
toolkit/render/bare/    MMIO framebuffer backend (Cortex-M, UART-PPM)
toolkit/render/uefi/    GOP linear-framebuffer backend (real display)
toolkit/render/desktop/ SDL2 backend -- real window, live mouse+keyboard, the
                        primary target for anything UI/visual, see below
toolkit/widgets/      STALE -- an unused leftover from an abandoned raw-Win32
                        windowing experiment two sessions ago (one file,
                        cursor.tr, never wired into anything real). Every
                        actual widget lives in toolkit/ui/ instead -- don't
                        add new files here, it's not where anything looks.
toolkit/text/          baked bitmap font atlas + lookup (real glyph rendering, all 4 tiers)
toolkit/input/         event types + PS/2 driver (bare) + host binding (dev)
toolkit/transport/     UART push protocol (bare) + file/socket watch (hosted)
toolkit/platform/      boot glue, allocator, timer — thin, OS-specific
examples/hosted_demo/  std tier, loads + hot-reloads a UI file
examples/bare_demo/    --freestanding Cortex-M, qemu-system-arm + UART-PPM
examples/uefi_demo/    --freestanding (no @entry) + hand-written zig UEFI stub,
                        qemu-system-x86_64 + OVMF, real display window.
                        render.tr = the minimal panel/text/button proof;
                        render_widgets.tr = the FULL widget set on bare UEFI
                        (see below); render_interactive.tr = the input shape
examples/uefi_demo/render_widgets.tr
                        every widget on a real firmware framebuffer, panel
                        centered via the markup's own justify-center/
                        items-center. Build with
                        build-uefi-turnkey.ps1 -Source ... -OutDir build-uefi-widgets
examples/desktop_demo/ real SDL2 window, live input, the original small demo
examples/widgets_demo/ every widget (checkbox/radio/switch/slider/progress/
                        dropdown/tabs/list) composed into one settings panel
tools/fonts/           JetBrainsMono.ttf (SIL OFL 1.1) + its license -- font-baking source
vendor/tauraroc/       the compiler binary + runtime/ headers it needs
verified-examples/     small .tr files confirmed to compile+run in this session
docs/proposal/          the actual spec (v2, current)
docs/tauraro-lang-reference/  upstream language/stdlib/dev docs, copied for offline reading
```

## Current status

**Phases 0–4 are built, compiling, and running** (hosted tier). `tauraroc --run
examples/hosted_demo/main.tr` from the repo root loads a UI file, parses it to a `UiNode` tree,
resolves class strings through the cached style table, lays it out, paints it to a `Canvas`, and
writes a PPM — then renders a *different* file through the *same* live `Interpreter`, which is
the live-reload half of the proposal's §9 definition of done.

Real modules, in dependency order (each imports only downward — Tauraro rejects circular imports,
so `toolkit/types.tr` exists to hold shared vocabulary and import nothing):

```
toolkit/types.tr              Color packing, Rect, Event        (imports nothing)
toolkit/ui/ast.tr             UiNode enum, boxing, depth guard
toolkit/ui/palette.tr         GENERATED: Tailwind 22 hues x 11 shades (scripts/gen-palette.sh)
toolkit/ui/scale.tr           Tailwind token suffix -> pixels (spacing/radius/border/fractions)
toolkit/ui/style.tr           utility tokens, Style, StyleCache
toolkit/ui/parser.tr          XML-like markup -> UiNode (see below)
toolkit/render/canvas.tr      the Canvas interface (width/height/fill_rect/set_pixel)
toolkit/render/hosted/buffer.tr  BufferCanvas + clipping + PPM
toolkit/text/font_data.tr     GENERATED: baked bitmap glyph atlas (scripts/bake-font.ps1)
toolkit/text/font.tr          Font: pixel_coverage(codepoint, col, row) -> 0..16
toolkit/layout/flex.tr        build/measure/place, row+col+gap+pad+grow (glyph size from font)
toolkit/ui/interp.tr          tree walk, real glyph painting, hit-test, handler allowlist
examples/hosted_demo/         main.tr + app.ui + app.reload.ui
```
## Class vocabulary: real Tailwind scales (changed 2026-09-06)

**A number in a class name is a Tailwind SCALE STEP, not a pixel count.** `p-4` is 16px
(4 x 0.25rem at a 16px root), where it used to mean 4px. Every `.ui` file and embedded
markup string in the repo was migrated in the same commit; the migration was verified by
byte-diffing the hosted demo's PPM output before and after, which is what proves the
translation is *consistent*. Correctness against the published scale is proven separately
by `verified-examples/tailwind_tokens.tr` (81 assertions).

Three modules, imported downward only:

- **`toolkit/ui/palette.tr`** — GENERATED, do not edit. 22 hues x 11 shades = 242 colors.
  Regenerate with `scripts/gen-palette.sh` from `scripts/tailwind-palette.txt`. It is
  generated because hand-typing 242 hex literals is a transcription-error machine and one
  wrong nibble renders as a plausible-but-wrong color no test would catch.
- **`toolkit/ui/scale.tr`** — token suffix -> pixels. Spacing follows Tailwind **v4's
  dynamic rule** (any integer step is `n * 4px`, so `p-13` is 52px) plus the four
  half-steps and `px`; radius and border-width are their own separate scales.
- **`toolkit/ui/style.tr`** — decides which `Style` field a prefix targets, and nothing
  else. Split into five per-family helpers; **read its header before merging them back
  together** (see the `__chkstk` note below).

### Gotchas worth knowing before writing markup

- **`border-4` is 4 PIXELS, `p-4` is 16px.** Border widths are literal pixels in Tailwind
  while spacing is a scale. That asymmetry is Tailwind's, not ours.
- **A bare hue means shade 500.** `bg-red` == `bg-red-500`. This CHANGED three legacy
  names: `bg-slate` used to be `0x1E293B`, which is actually slate-**800**. Markup now
  spells the shade (`bg-slate-800`). `steel`/`mist` survive as nebula extensions.
- **Arbitrary values** are Tailwind's own escape hatch and are supported wherever a scale
  value is: `w-[460px]`, `p-[17px]`, `bg-[#0B1120]`. The unit is optional. This is what the
  old `w-460` became, and it is deliberately uglier to type than `w-4` because reaching for
  an exact pixel count should be a decision.
- **Fractions are exact, not percentages.** `w-1/3` is carried as numerator/denominator and
  resolved against the parent's content box at layout time, so three of them fill a 300px
  row exactly (100 each). As 33% each they would leave a 3px gap.
- **Unknown tokens are ignored, exactly like typos** — silently, because UI content can
  arrive from outside the build and must never halt the renderer. `text-lg`, `shadow-md`,
  `opacity-50`, `z-10`, `absolute` all parse and do nothing. Each is absent because the
  renderer has no such concept, and `style.tr`'s header says which engine feature each
  would need first. Adding any of them is an engine change first and a token second.

### What the layout engine gained to support this

Per-side padding (`px-`/`py-`/`pt-`/`pr-`/`pb-`/`pl-`/`ps-`/`pe-`), margins including
negative (`-mt-4`), per-axis gap (`gap-x-`/`gap-y-`), fractional sizing (`w-1/2`, `w-full`,
`w-screen`), and `justify-around`/`justify-evenly`. A child's margins count toward its
parent's intrinsic size; a *fractional* child contributes nothing to it, matching CSS,
because its size is not known until the parent's is.

`examples/hosted_demo/tailwind.ui` exercises all of it and is rendered by
`verified-examples/tailwind_layout.tr`, which dumps geometry that was checked by hand.


## UI markup format: XML-like, not indentation-based (changed 2026-09-03)

The `.ui` format switched from an indentation-based syntax to angle-bracket markup, at the
user's direction — they want this toolkit usable for real OS-level UI (they previously shipped a
Rust UEFI DXE driver doing exactly that), and XML/HTML-shaped markup is what every editor already
has syntax highlighting for. See `examples/hosted_demo/app.ui` for a live example. Shape:

```
<panel "flex-col p-4 gap-3 bg-slate">
  <text "text-white">TAURARO UI TOOLKIT</text>
  <panel "bg-red grow" />
  <button "bg-amber grow" @on_click(on_ok)>
    <text "text-black">OK</text>
  </button>
</panel>
```

- The class string is a single **bare** quoted literal — no `class="..."` attribute name. This
  was a deliberate user choice (see the three options offered and picked in this session), not
  an oversight; `class="..."` was on the table and rejected.
- `@event(handler)` binds a host handler **name** to an event **name** — e.g. `@on_click(on_ok)`
  registers "on_ok" against the "on_click" event specifically. These are two separate strings in
  the AST (`UiNode.Element`'s `event_name` and `handler` fields), not one combined token, so a
  second event kind (e.g. `on_load`, a lifecycle event) is an `interp.tr`-only change later, not
  a format change. **Only `on_click` is wired to real dispatch today** —
  `toolkit.types.event_name_for_kind()` is the one place that mapping lives; a node written as
  `@on_load(...)` parses fine and simply never fires, because no lifecycle system exists yet.
- `<text "...">inner text</text>` — the one tag whose body is read **verbatim** up to the literal
  `</text>`, not re-parsed as markup. No mixed content anywhere else: every other tag's children
  are always child elements, never interleaved text.
- Self-closing (`<panel "..." />`) and open/close (`<panel "...">...</panel>`) are both supported;
  `#` starts a line comment, recognized only between tags.
- The parser (`toolkit/ui/parser.tr`) is a hand-written recursive-descent scanner over the whole
  source string (not line-based like the old format), with the same "never crash on malformed
  input" philosophy as before: unterminated tags, mismatched closing tag names, and bad `@event(`
  syntax are all recorded as errors and recovered from rather than aborting the parse.

## Bare metal on Windows — the toolchain half is SOLVED and verified

The freestanding path **works on Windows with no extra installs**, contrary to the earlier
assumption in this file. Verified on 2026-09-02 by building the SDK's own
`examples/freestanding/mps2_pure.tr`:

- `tauraroc <f>.tr --freestanding --emit c --emit-ld app.ld` emits C + a Cortex-M linker script.
- The **bundled `zig/zig.exe` cross-links it to a real ARM ELF** — confirmed 32-bit little-endian
  `EXEC`, `e_machine` 40 (ARM), entry `0x0` (the Cortex-M reset vector). No `arm-none-eabi-gcc`
  needed. The "MinGW is not a faithful freestanding target" warning in the docs is about using
  MinGW; it does not apply to cross-compiling with zig, which is what we do.

Use `scripts/build-bare.ps1`. **Two flags differ from the documented command**, both found by
running the documented one and reading the linker errors:

| Docs say | Use instead | Why |
|---|---|---|
| `-nostdlib` | `-nostartfiles` | `-nostdlib` also drops zig's compiler_rt, so every soft-float / 64-bit helper the Cortex-M3 lacks fails to link (`__aeabi_dsub`, `dmul`, `d2iz`, `i2d`, `uldivmod`, …). The arm-none-eabi path solves this with `-lgcc`. |
| *(nothing)* | `-fno-sanitize=undefined` | zig enables UBSan by default; nothing provides `__ubsan_handle_*` freestanding. |

`ld.lld: warning: cannot find entry symbol _start` is expected and harmless — on Cortex-M the
`.isr_vector` table drives reset. Also note: in PowerShell 5.1, do **not** pipe a native tool's
stderr with `2>&1`; it becomes ErrorRecords and trips `ErrorActionPreference=Stop` even on
success. The script redirects through `cmd /c` for this reason.

**The one missing piece is QEMU**, which is not installed. `winget install --id
SoftwareFreedomConservancy.QEMU` needs elevation, so it must be run from an **admin** terminal.
After installing, add `C:\Program Files\qemu` to PATH and run:
```
qemu-system-arm -M mps2-an385 -nographic -kernel build-bare\app.elf
```

**Target choice — do not follow the proposal's Phase 9 x86 assumption.** Tauraro generates boot
glue for **Cortex-M and RISC-V only** (`docs/.../11_bare_metal.md` §"Boot entry"). Going to x86
Multiboot2 means hand-writing the startup and linker script and giving up `@entry` / `--emit-ld`
entirely — maximum work, zero tool support. ARM/RISC-V is where the language actually helps.

The open sub-problem is that **mps2-an385 has no display** — it is UART-only. See next section.

## Bare metal: VERIFIED END TO END (2026-09-03)

QEMU is installed (`SoftwareFreedomConservancy.QEMU`, at `C:\Program Files\qemu` — not
automatically on PATH). The **entire toolkit now runs on bare metal**:

```
.\scriptsuild-bare.ps1 -Source examplesare_demo\main.tr
qemu-system-arm -M mps2-an385 -nographic -kernel build-barepp.elf > out.ppm
```

`examples/bare_demo/` renders a 64x48 frame on a Cortex-M3 with no OS, no libc and no
filesystem, streams it out the UART as a PPM, and reports
`dispatch button=true padding=false hits=1`. Parser, style cache, flexbox layout, interpreter,
rasteriser, hit-test and handler dispatch are the SAME toolkit source the hosted demo runs.
Only two things are substituted: `BufferCanvas` (needs `io.file`) becomes `FrameBuffer`, and the
UI file becomes a string compiled into the image.

### Three freestanding compiler bugs found the hard way

All three cost hours; none is in our code. Each was reduced to a minimal repro.

1. **Calling ANY first-class function value hangs.** Not Dict-specific, not toolkit-specific:
   `mut f: def(int) -> int = add1` then `f(41)` hangs in a standalone freestanding program.
   Assigning the value works; *calling* it never returns. Works fine hosted.
   **Consequence:** the proposal's 5.5 `Dict[str, def(Event) -> void]` handler table CANNOT
   work bare-metal. The toolkit now uses a `pub interface EventHandler` instead — interface
   vtable dispatch works on both tiers (the `Canvas` backend already proved it).
2. **A private recursive method returning `str` hangs.** `Interpreter.hit` did; the
   byte-identical logic as a free function (`hit_test`) does not. `Interpreter.paint` is also
   private and recursive but returns `void` and is fine, so the trigger looks like the string
   return, not the recursion. Keep recursive string-returning helpers as free functions.
3. **`register` is a C keyword.** A `pub def register(...)` emitted as a C symbol gets mangled
   to `_tr_fn_register` and *silently loses the interface upcast*, producing a confusing
   `passing 'char *' to parameter of incompatible type 'TrStr'`. Avoid C keywords as public
   function names (`register`, `auto`, `extern`, `inline`, `restrict`, ...).

### The bump allocator in the SDK example is subtly broken — do not copy it

`examples/freestanding/mps2_pure.tr` defines `@realloc` as `return heap_alloc(n)`: it allocates
fresh memory and **never copies the old contents**. That example never grows a collection so the
bug is invisible there, but every `List`/`Dict` append reallocs. The symptom is maddening — the
parser reports `parse: ok` and returns **exactly one node**, holding the *last* line of input.
A correct arena for this toolkit needs all four of:

- **realloc must COPY** the old bytes.
- **grow in place when the block is the newest allocation** (track `_last_ptr`), or repeated
  appends are O(n^2) and a 64x48 framebuffer never finishes on an emulated M3.
- **never move `_heap_next` backwards** on a shrinking realloc, or the freed tail is handed out
  while the block is still live — this showed up as a hang in an unrelated `Dict` lookup.
- **never return a zero-length block**; round up and enforce a minimum, or two live objects
  share an address.

Also: the bare `FrameBuffer` uses `Vec[int].init(w*h)` rather than `List[int]` + `append`,
because `Vec` reserves the exact final size up front and never reallocs.

## UEFI: real display, VERIFIED END TO END (2026-09-03) — now the primary target

Direction changed deliberately (user has prior experience shipping a Rust UEFI DXE driver and
wants this toolkit usable for real OS-level UI, e.g. a boot-time login screen — the display path
matters more here than the Cortex-M/UART route). **UEFI is a materially better target than
Cortex-M for this project**, and, contrary to first assumption, it is *less* work, not more:
firmware already did reset vectors, memory setup, and the boot menu, and it hands a real
already-mapped linear framebuffer (GOP) directly to the caller — no MMIO display driver to write,
no PPM-over-UART round trip, no `@entry`/`--emit-ld` at all.

```
.\scripts\run-uefi.ps1
```

builds `examples/uefi_demo/` and boots it under `qemu-system-x86_64 -M q35` with OVMF firmware
(shipped inside the QEMU install, nothing extra to fetch), opening a **real graphical window**
showing the toolkit's actual render — parser, style cache, layout, interpreter, `EventHandler`
dispatch, all unchanged from the Cortex-M tier. `-NoWindow` runs headless and captures an
automated screenshot via QEMU's monitor `screendump` command for verification without a human
watching.

### The shape: Tauraro is not the boot glue here — a thin zig stub is

Tauraro's `--freestanding` only generates boot glue for Cortex-M and RISC-V (see below); it does
not know the PE/COFF UEFI ABI or protocol tables, and does not need to, because UEFI firmware
already **is** the boot glue. The split:

- `examples/uefi_demo/boot.zig` — ~50 lines, hand-written. The real UEFI entry point. Calls
  `BootServices.allocatePool()` for a heap block, locates the GOP protocol for a framebuffer
  pointer + resolution + `PixelsPerScanLine`, then calls two Tauraro-exported functions.
- `examples/uefi_demo/render.tr` — plain Tauraro, compiled with `tauraroc render.tr
  --freestanding --emit c` (**no `@entry`, no `--emit-ld`** — confirmed unnecessary: a
  `pub export def` with no `@entry` anywhere in the program compiles and links fine standalone).
  Exports `tauraro_heap_init(base, size)` and `tauraro_ui_render(fb, width, height, pitch)`. Still
  needs `@allocator`/`@free`/`@realloc`/`@calloc` — `--freestanding` always defines
  `TAURARO_KERNEL`, which `#error`s at actual C-compile time (not at `--emit c` time) if those
  aren't supplied, regardless of `@entry`. Same proven copy+grow-in-place+no-shrink+no-zero-block
  allocator design as the Cortex-M tier (tau_bugs.txt #4), just parameterized on a pool pointer
  from `AllocatePool` instead of a hardcoded MMIO-adjacent SRAM address.
- `toolkit/render/uefi/gop.tr` — the third `Canvas` backend. The thinnest of the three: GOP's
  common `PixelBlueGreenRedReserved8BitPerColor` mode stores bytes `[B,G,R,reserved]`, which read
  as a little-endian 32-bit word is exactly `0x00RRGGBB` — the same packing `toolkit.types.rgb()`
  already produces, so a `Style` color writes straight into the framebuffer with zero conversion.
  (If a target ever reports the RGB-ordered variant instead, colors would need byte-swapping —
  not hit yet, not handled.)
- `scripts/build-uefi.ps1` — `tauraroc --freestanding --emit c`, then **one** `zig build-exe`
  invocation mixing the `.zig` stub and the generated `.c` files directly (`build-exe` accepts
  both; no separate object-file or linker step needed).
- `scripts/run-uefi.ps1` — boots it under QEMU + OVMF, with the `-serial file:`-style robustness
  already learned from the Cortex-M runner script.

**Updated 2026-09-04**: the hand-written `boot.zig` + `scripts/build-uefi.ps1`'s manual `zig
build-exe` step are no longer strictly necessary. `tauraroc` now has a turnkey UEFI target:

```
tauraroc examples\uefi_demo\render.tr --target uefi-x64 --freestanding -o app
```

produces `app.efi` directly (real MZ/PE header; **now screenshot-verified end to end**, 2026-09-04
follow-up session — `scripts/build-uefi-turnkey.ps1` + `scripts/run-uefi.ps1 -OutDir
build-uefi-turnkey -Build:$false` renders the exact same "TAURARO ON UEFI" panel/text/button layout
under qemu+OVMF as the `boot.zig` baseline, pixel-identical in kind, not just "survives to hlt").
Two portability fixes landed in `run-uefi.ps1` alongside this verification, both applicable
regardless of which UEFI build script produced the `.efi`:
- OVMF auto-detection now tries winget's single-file layout first, then MSYS2's SPLIT code/vars
  layout (`pacman -S mingw-w64-x86_64-qemu`) as a fallback — this box only has the MSYS2 one, and a
  single read-only pflash drive with a code-only image fails to load at all ("could not load PC
  BIOS"); needs a second writable pflash drive for vars.
- MSYS2's OVMF build shows its own TianoCore boot-manager menu before loading `BOOTX64.EFI` (the
  winget layout apparently doesn't, or didn't when this was last verified) — `run-uefi.ps1` now
  sends `sendkey ret` a few times over the monitor connection to dismiss it automatically; default
  `-BootSeconds` bumped 10 -> 20 to cover menu-dismiss + actual app boot. Also fixed: HMP's
  `screendump` path arg needs forward slashes (backslash is an HMP escape prefix) and quoting (a
  username with a space breaks unquoted whitespace-split args); a stray relative-path bug in the
  screenshot Test-Path/ReadAllBytes calls that silently resolved against a stale unrelated
  directory across long-lived PowerShell sessions.
Same `_WIN32`/`_WIN64`/`_MSC_VER` undef and same well-known-named-export contract
(`tauraro_heap_init(base, size)` + `tauraro_uefi_main`/`tauraro_ui_render(fb, width, height,
pitch)`) — `render.tr` needed zero changes, it already used `tauraro_ui_render`. The compiler
auto-generates an equivalent, protocol-agnostic zig glue stub internally (not written to disk for
inspection) and drives `zig build-exe -target x86_64-uefi` itself; still depends on `zig` (bundled
in the SDK) as the linker, same as every other Tauraro cross target — the "no hand-written stub"
part is what's new, not "no zig at all". `boot.zig`/`build-uefi.ps1` still work unchanged and
remain the reference for anything beyond the two-export convention (e.g. reading input devices,
multiple windows, custom heap sizing).


### A third UEFI-only failure: `__chkstk` (2026-09-06)

**A function with a stack frame larger than 4KB fails to LINK on `--target uefi-x64`,
and only there.** Found while building the Tailwind token table: `apply_utility` started
life as one long if/elif chain over ~40 token prefixes, each branch with its own `mut`
local. It compiled and ran correctly hosted, on Cortex-M, and in the SDL2 window; the
UEFI link then failed with

```
lld-link: undefined symbol: __chkstk
  note: referenced by module_toolkit_ui_style.c  (apply_utility)
```

`__chkstk` is the **Microsoft x64 ABI's stack-probe helper**. Any compiler targeting that
ABI emits a call to it for a frame bigger than one 4KB page, so the guard page is touched
in order rather than skipped over. UEFI shares the Microsoft x64 ABI (it is PE/COFF, which
is the whole reason `_WIN32` gets predefined — see above) but is freestanding, so nothing
supplies the helper.

Not strictly a Tauraro bug: the codegen is doing the correct thing for the ABI. It is a
**gap in the `uefi-x64` target**, which should either provide a `__chkstk` (it is ~10
instructions) or compile with `-mno-stack-arg-probe`. Until it does, the constraint is
real and worth knowing, because:

- it is invisible on every other tier, so it surfaces long after the code looks correct;
- the error names a symbol that appears nowhere in your source;
- the trigger is *total locals in one function*, not recursion or allocation, so it grows
  silently as a function accumulates branches.

Worked around in `toolkit/ui/style.tr` by splitting the chain into five per-family helpers
(`apply_flex_token`, `apply_edge_token`, `apply_spacing_token`, `apply_size_token`,
`apply_color_family_token`), which keeps every frame well under a page and reads better
anyway. That file's header carries the same warning next to the code, so the split does not
get "tidied" back into one function later.

> **Note:** `tau_bugs.txt`, referenced throughout this file as the running defect log, is
> **not present in the repo** — it appears never to have been committed. Findings like this
> one are being recorded here instead until it reappears.
### Two new bugs found getting here (full detail in `tau_bugs.txt` #12)

- zig's `x86_64-uefi` target legitimately predefines `_WIN32`/`_WIN64`/`_MSC_VER` (UEFI really
  does share the Microsoft x64 ABI and PE format), but `tauraro_rt.h` treats bare `_WIN32` as
  "real hosted Windows, `windows.h`/`psapi`/`bcrypt` are available" without checking
  `TAURARO_KERNEL` first, so freestanding UEFI builds fail with `'windows.h' file not found`
  unless those three macros are explicitly undefined at compile time
  (`-cflags -U_WIN32 -U_WIN64 -U_MSC_VER --` bracketed before the `.c` sources in the
  `zig build-exe` invocation — a bare top-level `-U_WIN32` is rejected by `build-exe`).
- `New-Object System.Drawing.Bitmap($w * $Scale, $h * $Scale)` — PowerShell's
  parenthesized-constructor shorthand for `New-Object` only reliably evaluates bare variables
  inside the parens, not expressions; use `-ArgumentList` explicitly instead. Not a Tauraro bug,
  but cost real time in `scripts/ppm-to-png.ps1`.
- (Also relearned, not new: `Start-Process -ArgumentList` with a PowerShell array does not
  reliably quote elements containing spaces in PS 5.1 — both the OVMF path and the ESP directory
  are typically under `C:\Program Files\...`. Build one pre-quoted string instead, same pattern
  `build-bare.ps1`/`build-uefi.ps1` already used for the C-compiler invocations.)

## Text rendering (Phase 6): DONE — real bitmap font on all three tiers (2026-09-03)

Real, legible text now renders on hosted, Cortex-M, and UEFI — replacing the old
one-block-per-character placeholder. The approach: **bake a TTF into a fixed bitmap glyph atlas
offline, ship only the resulting byte data.** Tauraro's stdlib has zero font/curve-rasterizer
support (confirmed by searching `std/`), and real TTF outlines are quadratic Beziers wanting
float/fixed-point scanline rasterization — a large, risky thing to write from scratch and get
right on freestanding targets that also have no filesystem to load a `.ttf` from at runtime. A
baked atlas turns "render text" into a lookup + blit: no curve math, no float dependency,
identical on all three tiers because it's just data.

- **Font source:** `tools/fonts/JetBrainsMono.ttf` (SIL OFL 1.1, license alongside it). No
  Python in this environment — baking uses `scripts/bake-font.ps1` and .NET's `System.Drawing`
  (GDI+): renders each glyph supersampled 4x with real antialiasing, then box-downsamples back
  to a crisp 1-bit-per-pixel 8x14 cell. Covers ASCII 32–126 (95 glyphs), emits
  `toolkit/text/font_data.tr` — 1330 bytes as one `List[u8]` literal (confirmed compiling fine
  at this size; no issue at this scale).
- **`toolkit/text/font.tr`** — the lookup: `Font.pixel_coverage(codepoint, col, row) -> int`,
  0..16. An out-of-range codepoint or pixel returns 0 unconditionally (renders as blank space,
  never a crash) — text content is not trusted input. **(Superseded 2026-09-05: this was
  `pixel_set(...) -> bool` over a 1-bit atlas until the antialiasing pass below; the atlas is
  now one coverage byte per pixel, 10640 bytes.)**
- **`Canvas` interface gained a 4th method**, `set_pixel(x, y, color)` — a baked glyph is an
  irregular per-pixel pattern, `fill_rect` alone can't draw one. Deliberately NOT a
  `draw_glyph(codepoint, ...)` method: that would couple every backend to font lookup. All three
  backends (`BufferCanvas`, `FrameBuffer`, `GopCanvas`) implement it; `interp.paint_text` does
  the font lookup and calls `set_pixel` per foreground bit.
- **`toolkit.layout.flex`'s `glyph_w()`/`glyph_h()`** — previously hardcoded placeholders (6x10)
  — now delegate to the real baked font cell size (8x14), so layout automatically matches what
  gets painted with zero other changes.
- Interpreter now owns a `Font` (loaded once in `Interpreter.init()`), not passed around
  separately.

**A real, deep bug found and fixed getting here** (full detail in `tau_bugs.txt` #4's update):
`toolkit/render/bare/framebuffer.tr`'s `emit_ppm` allocated a FRESH `StringBuilder` per row and
never freed any of them (bump allocator) — on a bigger canvas with real text this accumulated
enough that a `StringBuilder` being grown was no longer the newest allocation, so the realloc
slow path's read ran past `_heap_next` into unmapped memory: a Cortex-M bus fault with no
handler installed, which presents as a silent hang with zero further UART output. Fixed by
reusing one `StringBuilder` via `.clear()` (resets length in place, no realloc) across all rows,
and by using `.as_str()` instead of `.to_string().as_str()` (the latter allocates a fresh copy
on every call).

**A second, NOT fully root-caused bug also found on the Cortex-M tier** (`tau_bugs.txt` #13):
certain specific packed RGB color values (amber `0xF59E0B`, violet `0x8B5CF6`), certain
same-row color combinations, and certain canvas widths (96 hangs, 88 does not, otherwise
identical) each independently trigger the same kind of silent hang — confirmed present hosted
NOT and on UEFI NOT (both render amber/violet correctly), so this is specific to
`--freestanding`/thumb-freestanding-eabi/cortex_m3. Worked around in `examples/bare_demo/` by
using only colors and a canvas width empirically confirmed to complete; the underlying mechanism
is still unknown and would need disassembly of the generated code to chase further.

## Desktop tier (SDL2): a real live window, full modern widget set, anti-aliased (2026-09-05)

A collaborator added a fourth `Canvas` backend, `toolkit/render/desktop/sdl_canvas.tr`
(`SdlCanvas`), wrapping real SDL2 windowing/input via `toolkit/render/desktop/sdl_bindings.tr`
(1670 symbols, `tauraroc bindgen`-generated). This is the only tier with a real live window and
continuous mouse/keyboard input rather than a single static frame — `examples/desktop_demo/`
demonstrates it. **`SDL2.dll` is gitignored, not committed** — `scripts/build-desktop.ps1`
expects a local MSYS2 install (`C:\msys64\mingw64\...`). On a machine without MSYS2 (this one,
both sessions), the workaround: generate an MSVC-compatible `SDL2.lib` straight from a fetched
official `SDL2.dll` (no MSYS2 needed) —
```
Invoke-WebRequest https://github.com/libsdl-org/SDL/releases/download/release-2.30.9/SDL2-2.30.9-win32-x64.zip -OutFile sdl2.zip
# extract SDL2.dll from it, then:
dumpbin /exports SDL2.dll > exports.txt   # from a VS install's Hostx64\x64 bin
# build a LIBRARY SDL2 / EXPORTS .def from the export names, then:
lib /def:SDL2.def /out:SDL2.lib /machine:x64
tauraroc examples\desktop_demo\main.tr -o app.exe --link SDL2.lib   # NOT -lSDL2 -- that
                                                                     # fails with "searched
                                                                     # paths: none", tauraroc's
                                                                     # -l resolution doesn't
                                                                     # search the CWD.
```
`SDL2.lib` (but not the fetched `SDL2.dll`, per the gitignore rule above) is committed at the
repo root from this session so it doesn't need re-deriving.

### Widget expansion (this session): checkbox, radio, switch, slider, progress, dropdown, tabs, scroll list

Before this session there was exactly one real interactive widget, `TextInput`
(`toolkit/ui/textinput.tr`). Eight more now exist, all under `toolkit/ui/` (matching
`textinput.tr`'s actual location — `toolkit/widgets/` in the repo layout table is a stale
leftover from an abandoned raw-Win32 windowing experiment two sessions ago, not a pattern
anything real follows): `checkbox.tr`, `radio.tr`, `switch.tr`, `slider.tr`, `progress.tr`,
`dropdown.tr`, `tabs.tr`, `list.tr`. `examples/widgets_demo/` composes all eight into one
settings-panel-shaped window (header card + shadow, a Tabs strip, Checkbox/Radio-group/Switch,
a Slider driving a ProgressBar live, a Dropdown, a mouse-wheel-scrollable list, footer buttons)
— verified building and running live, screenshotted, confirmed correctly rendered.

**Two real architectural findings from building this, worth knowing before adding more:**

1. **The parser was already fully tag-agnostic** — `UiNode.Element(tag, ...)` accepts any
   identifier with zero grammar changes, and layout/paint (`toolkit/layout/flex.tr`,
   `Interpreter.paint`) branch on `LayoutBox.kind` (text vs. element) and `Style` fields, never
   on `tag` name. So **Card/Divider/Badge needed no new code at all** — they're just existing
   `Style` tokens (`radius-`, `border-`, `bw-`, `bg-`) composed in markup or via direct
   `paint_rounded_rect`/`draw_text` calls; only genuinely *stateful* widgets (checked?, dragging,
   selected index, scroll offset) need a host-owned class, because `Interpreter.render()` rebuilds
   the whole `LayoutBox` tree from a **static class string** every call — see `textinput.tr`'s own
   header comment, which every new widget file points back to instead of re-deriving.

2. **`render_to()` cannot paint into a sub-rect.** `toolkit.layout.flex.layout_tree` always sizes
   the root of whatever tree it's given to fill the *entire* canvas (`c.width()`/`c.height()`) —
   there is no viewport/sub-region parameter. A second `render_to()` call for "just the tab
   content" repaints the WHOLE window, erasing whatever chrome was already drawn. Found by
   actually running the demo: the header card and its shadow were invisible because the tab
   content tree, rendered second, silently painted over them from `(0,0)` again. Fixed by
   host-painting per-tab content directly (`paint_tab_content` in `examples/widgets_demo/main.tr`)
   rather than swapping full-canvas `UiNode` trees — the same host-paints-the-dynamic-part pattern
   `TextInput`/`examples/uefi_demo/render_interactive.tr` already use, just applied to
   per-tab content instead of per-field text.

### Anti-aliasing: real, portable, computed by hand (no alpha channel anywhere in Canvas)

The very first widgets_demo screenshot showed visibly jagged circles (radio dots, switch knob,
slider thumb) and rounded-rect corners — every existing shape primitive
(`fill_circle`/`paint_corner`/`paint_rounded_rect`) is a hard in/out pixel test, no softening.
`Canvas.set_pixel` takes one final solid color and nothing else — no alpha, no destination
read-back — and the bare-metal/UEFI framebuffer backends are plain write-only memory that
genuinely cannot blend even in principle. So `toolkit/ui/interp.tr` gained `fill_circle_aa` /
`paint_rounded_rect_aa`: each boundary pixel is supersampled on a 4x4 subgrid (16 integer-math
sample points per pixel, no floats), and the BLENDED COLOR ITSELF is computed in Tauraro — a
straight per-channel mix of the shape's own color and a caller-supplied flat backdrop color,
weighted by how many of the 16 subsamples land inside — before that one final color is ever
handed to `set_pixel`. Fully portable (works through the same four-method `Canvas` interface
every backend already has), at the cost of the caller having to know what flat color is already
sitting behind the shape it's about to draw (every widget got a `page_bg` field, defaulted to
this demo's `0x0B1120`, for exactly this).

## Full-path antialiasing, text, borders, alignment, DPI (2026-09-05, second pass)

The first AA pass above covered only the six host-owned widgets that draw circles or rounded
corners. This pass finished the job, guided by **`RASTERIZER.md`** at the repo root — read that
before touching any shape primitive; it is the spec this rasterizer is now written against, and
§5 (supersampling instead of coverage buffers), §5c (borders), §5d (integer blending) and §12
(how to add a shape) are the sections that matter most. Verified on **all four tiers**: hosted
PPM, Cortex-M3 under qemu, UEFI/OVMF screenshot, and the live SDL2 window.

**1. The font atlas is antialiased now, not 1-bit.** Hard-edged 8x14 letterforms were the single
most visible "not smooth" thing on screen, more than any corner. `scripts/bake-font.ps1` now
emits one **0-16 coverage byte per pixel** instead of a bit (10640 bytes, up from 1330), and
`draw_text` blends each partial pixel against a caller-supplied backdrop with the same
`mix_color` every shape uses. `Font.pixel_set` became `Font.pixel_coverage`.

**2. `draw_text` is now the ONE glyph loop.** There were three copies of it (interp, textinput,
and each new widget); changing the atlas format would have meant fixing the same blend math in
three places. Its signature gained a `bg` parameter — every call site has to say what flat color
the text is sitting on, which is the same requirement every AA function here already had.

**3. `Interpreter.paint` threads an ambient background through the recursion.** Each box passes
its own resolved `bg` down as its children's backdrop (and an unfilled panel passes through
whatever it inherited, because a transparent panel really is transparent). `Interpreter.root_bg`
(default `0x0B1120`) seeds it and **must match the canvas clear color** — `examples/bare_demo`
sets it to black for exactly this reason. This is what the previous pass listed as future work.

**4. Borders are a real ring now, not two overlapping fills** (`RASTERIZER.md` §5c). Drawing an
outer rounded rect in the border color and an inset one in the fill color *ghosts*: the inner
fill's AA ramp blends toward solid border over pixels that are themselves already a
border/ambient mix, leaving a lighter halo tracing every corner. No choice of backdrop argument
fixes it — the information isn't available to the second call. `paint_rounded_box_aa` (and its
circular twin `fill_circle_ring_aa`, for radio dots and slider thumbs) resolve fill/ring/ambient
**per subsample in one pass** via `mix3_color`, so there are no longer two ramps to disagree.
`paint_rounded_rect_aa` and `fill_circle_aa` remain for the un-bordered case.

**5. `mix_color` was missing its rounding correction.** `(a*c + b*(16-c)) / 16` truncates, which
biases every blended pixel about half a level toward black — one pixel is nothing, a whole UI's
worth of edges is a faint dark fringe around every corner and glyph. Now `+ 8` before the divide
(`RASTERIZER.md` §5d).

**6. Layout gained real `justify-*` / `items-*` alignment** (`toolkit/layout/flex.tr`,
`toolkit/ui/style.tr`) — Tailwind's own spelling, so the vocabulary carries over. This stopped
being optional the moment the toolkit had buttons: a `<button>` wrapping a `<text>` put its label
hard against the top-left corner, which reads as broken next to any real UI, and padding can't
fix it because the label's size varies with its content. `justify-center items-center` is the
whole fix; every demo's buttons now carry it. `items-stretch` stays the default, so no existing
`.ui` file changed behavior. `grow` and `justify` deliberately don't fight: a box with a growing
child has no leftover main-axis space, so justify is a no-op there, same as real flexbox.

**7. The SDL window is DPI-aware** (`SDL_SetHint("SDL_WINDOWS_DPI_AWARENESS", "permonitorv2")`,
**before** `SDL_Init` — the hint is only read during video-subsystem startup). Without it Windows
renders at the requested logical size and then bitmap-stretches the finished frame up to physical
pixels, which bilinearly re-blurs every antialiased edge the rasterizer just computed at 16
subsamples per pixel. This also resolves the earlier session's "GetWindowRect returns a bigger
footprint than requested" note: that was real, it was this, and it's fixed. (Note for anyone
measuring it again: a *measuring* process must call `SetProcessDPIAware()` too, or it gets
virtualized coordinates back and the numbers won't line up with what's on screen.)

## The full widget set on bare UEFI (2026-09-05) — `examples/uefi_demo/render_widgets.tr`

`render.tr` proves the UEFI pipeline with three colored boxes and two buttons. This one proves
the pipeline is good enough to build a real OS-level screen with: **every widget the desktop tier
has — checkbox, radio group, switch, slider, progress bar, dropdown (rendered OPEN, with a hovered
row), tab strip, scrolling list, plus card/divider/badge — on a firmware framebuffer with no OS,
no libc, no filesystem and no window manager.** Screenshot-verified under qemu+OVMF at 1280x800.

```
.\scripts\build-uefi-turnkey.ps1 -Source examples\uefi_demo\render_widgets.tr -OutDir build-uefi-widgets
.\scripts\run-uefi.ps1 -OutDir build-uefi-widgets -Build:$false          # add -NoWindow to auto-screenshot
```

**Nothing in `toolkit/` changed to make this work.** It is the same source
`examples/widgets_demo/main.tr` runs in an SDL2 window, at the same pixel offsets, so the two
tiers render an identical panel. Exactly three things differ, and all three are inherent to the
tier rather than to the widgets:

1. `SdlCanvas` -> `GopCanvas`. That is the entire porting cost.
2. **No event loop.** No pointer/keyboard driver is wired up on this tier yet, so each widget is
   constructed in a deliberately non-default state (checkbox checked, *second* radio selected via
   `select_only`, switch on, slider at 65%, dropdown open on a hovered row, a list row selected)
   rather than responding to input. Those are all plain `pub` fields — a Simple Pointer / Simple
   Text Input driver would set them exactly the way the SDL loop does. `Switch` needs no `tick()`
   here because `init()` already seeds `knob_pos` to the settled end of its travel.
3. **No drop shadow.** `SdlCanvas.draw_shadow` uses SDL's alpha blend modes; a write-only GOP
   framebuffer cannot blend. The antialiasing is unaffected — it never needed alpha, which is the
   whole point of the §5 design, and is why it looks identical on all four tiers.

**The panel is centered by the markup, not by arithmetic**, which is the first real use of the
alignment tokens: an outer full-screen `<panel "flex-row justify-center items-center">` around a
fixed `w-460 h-560` child. Before those tokens this was not expressible in markup at all. The
host-painted widgets then read their origin back off the laid-out tree
(`it.root.children[0].x/y`) rather than recomputing the centering — so if the panel's size or the
centering rule changes, they follow instead of silently drifting.

## What's next — the plan

Full detail and rationale in `docs/proposal/proposal-v3-cross-platform-engine.md` §5. Ordered
by value delivered per unit of risk, not by dependency convenience. Each phase is
independently shippable and leaves the repo working.

**Phase 1 — unblock the freestanding tiers. ✅ DONE (2026-09-06).** UEFI is now a live,
interactive tier, not a still image.
1. ~~Per-frame arena reset~~ — `toolkit/platform/arena.tr`, one shared arena with
   `arena_mark()`/`arena_release()`, replacing the ~80-line allocator that was
   copy-pasted into four programs. Verified on Cortex-M3: four renders, arena usage
   identical across frames.
2. ~~A UEFI input driver~~ — `examples/uefi_demo/boot_interactive.zig` +
   `render_live.tr`. A real frame loop with AbsolutePointer (or SimplePointer) and
   ConIn, hover feedback, click dispatch, a draggable slider, and Esc to exit.
   **This is the login screen's foundation.**

Three findings from Phase 1b, each recorded next to the code because each presents as
something other than what it is — see `render_live.tr`'s header and the UEFI section above:
module-level `mut` initializers DO NOT RUN AT ALL on freestanding targets, so a global
`SomeClass.init()` is permanently null AND a scalar with a non-zero default is silently zero;
adding a USB device reshuffles OVMF's boot order onto the Shell (fixed with a generated
`startup.nsh`, which also usefully *prints* crash reasons);
and painting straight to the GOP scanout means a screenshot catches a half-drawn frame,
which cost two rounds of chasing layout bugs that did not exist.

**Phase 2 — the browser backend. ✅ DONE (2026-09-06).** `toolkit/render/web/canvas.tr` +
`examples/web_demo/` + `scripts/build-web.ps1`. Nebula renders in a browser tab from the same
engine every other tier runs. Build: `--target wasm --freestanding --emit c`, then
`zig build-exe -target wasm32-freestanding -fno-entry -rdynamic`. The result imports NOTHING
(no WASI), so the host page needs only `WebAssembly.instantiate` with an empty import object.
Pixels cross the boundary by not crossing it — Tauraro renders into WASM linear memory and JS
wraps those exact bytes in an `ImageData`. ABI: `int`/`usize` are i64 (BigInt in JS),
`Pointer[T]` is i32 (Number). The one per-backend difference is byte order: `ImageData` is
[R,G,B,A] where every other backend wants [B,G,R,X], so `WebCanvas` repacks — getting that
wrong silently swaps red and blue.

**Phase 3 — the `nebula` CLI.** `init` / `dev` / `run --<target>` / `build`. Generates each
tier's entry point including the ~80-line bump allocator currently copy-pasted into four
programs, and absorbs the four PowerShell scripts and their flag folklore. *Settle whether
Tauraro can list directories and spawn processes before designing this* — it decides whether
the CLI is a Tauraro binary or a Tauraro core plus a shell wrapper.

**Phase 4 — app structure.** Folder-based screens resolved at BUILD time (no filesystem on
freestanding tiers, so codegen emits markup as string constants), `layout.ui` composition,
`goto:` navigation — which needs no grammar change, since the AST already stores handler names
as opaque strings — and hot reload on `nebula dev`.

**Phase 5 — mobile.** Android and iOS through the existing `SdlCanvas`; plausibly mostly build
configuration, since SDL2 supports both and the bindings already exist.

**Phase 6 — engine depth**, in demand order: multiple font sizes (currently the most visible
authoring limit — `text-lg` parses and does nothing), gamma-correct blending
(`RASTERIZER.md` §3), sub-rect rendering (removes the entire host-paint-the-dynamic-part
workaround class), diffing, `templa` integration, then images/per-corner radii/shadows.

### Open questions to settle with a compiling probe, not by reading docs

1. Can Tauraro list directories and spawn processes? (blocks Phase 3's shape)
2. What does WASM interop look like — exports to JS, imports from it? (blocks Phase 2)
3. Does SDL2 actually cross-build for `android-arm64`/`ios`? (decides if Phase 5 is days or weeks)
4. Is `--no-heap` viable for the smallest embedded targets? (the engine uses `List`/`Dict`
   throughout, so probably not without a parallel data path)
5. What is `templa`'s syntax and integration surface? (ask, before building the slot)

### A standing rule for backends

Backends stay tiny because `Canvas` is four methods. **If a backend starts growing
engine-shaped code, that is the signal something belongs in the core instead.** And
"pixel-identical across tiers" is this project's strongest claim — it only stays true if it is
checked, so byte-diffing renders should be the standard check for every backend (it already
caught one regression).

### Cortex-M/UART tier — kept working, no longer the priority

Still fully functional (`scripts/build-bare.ps1` / `scripts/run-bare.ps1`,
`examples/bare_demo/`) and worth keeping green as a regression check — it's the only tier that
exercises Tauraro's own generated boot glue (`@entry`/`--emit-ld`) — but no further investment
planned unless a real Cortex-M target becomes relevant again.
