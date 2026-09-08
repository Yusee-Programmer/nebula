Nebula 1.0 — Revised Architecture Proposal
A Modern, High-Performance, Cross-Platform UI Engine for Tauraro

Goal
Build a complete, modern UI engine where:

    Layouts are guaranteed identical across every platform.
    Developers work primarily on Desktop / Browser (fast iteration).
    The same UI runs with high quality on Desktop, Android, iOS, TVs, Browser, and still works on UEFI / bare-metal / custom hardware.
    Performance is competitive with modern frameworks.
    Pixel-perfect identity is not required (only layout + visual consistency).

1. Core Design Principles

    Layout is sacred
    The layout engine is the single source of truth. Every backend receives the exact same computed rectangles, styles, and widget tree.
    Two rendering tiers
        Modern Tier (Desktop, Mobile, TV, Browser) → High quality, GPU-accelerated
        Extreme Tier (UEFI, bare-metal, very constrained hardware) → Software fallback
    Development experience first
    95% of development happens on Desktop (SDL2) or Browser. Bare-metal is a deployment target, not the primary development environment.
    Retained mode + dirty regions
    Only redraw what changed.
    SDL2 as the primary modern backend
    SDL2 already covers Desktop + Android + iOS + many embedded/TV platforms with one codebase.

2. New Architecture

┌──────────────────────────────────────────────────────────────┐
│                     Application Layer                         │
│  .ui markup  +  .tr logic  +  components  +  routing          │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────────────────────────────────────────────────┐
│                     Nebula Core (Platform Agnostic)           │
│                                                              │
│  • Markup Parser                                             │
│  • Style System (Tailwind-compatible)                        │
│  • Flexbox + Grid Layout Engine                              │
│  • Widget Tree + State Management                            │
│  • Event System + Hit Testing                                │
│  • Animation & Transition System                             │
│  • Theme & Design Tokens                                     │
│                                                              │
│  Output: Fully resolved Scene Graph (rects, styles, z-order) │
└──────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
┌─────────────▼─────────────┐   ┌─────────────▼─────────────┐
│   Modern Renderer         │   │   Software Renderer       │
│   (Primary Path)          │   │   (Extreme Path)          │
│                           │   │                           │
│  • SDL_Renderer / SDL_GPU │   │  • Current Canvas model   │
│  • WebGPU / Canvas2D      │   │  • 4×4 supersampling      │
│  • Future: Metal/Vulkan   │   │  • Write-only framebuffer │
│                           │   │                           │
│  High quality, AA,        │   │  Guaranteed to run on     │
│  shadows, blur, etc.      │   │  any 32-bit framebuffer   │
└───────────────────────────┘   └───────────────────────────┘

3. Key Technical Decisions
A. Layout Guarantee

    Layout engine runs once and produces a platform-independent scene graph.
    Every backend only paints the already-computed rectangles.
    Result: Identical layouts on Desktop, Browser, Android, iOS, and bare-metal.

B. Rendering Strategy
Platform	Renderer Used	Quality Level	Notes
Desktop (Windows/macOS/Linux)	SDL_GPU / SDL_Renderer	High	Primary development target
Android / iOS	SDL2	High	Same code as desktop
Smart TVs	SDL2	High	Most TVs support SDL2 or similar
Browser	WebGPU or Canvas2D	High	Fast iteration + sharing
UEFI / Bare-metal	Software Renderer	Medium	Correct layout, acceptable quality
Custom Hardware	Software or custom	Configurable	Fallback always available
C. Modern Features (Must Have)

    Retained mode scene graph
    Dirty region / partial redraw
    Hardware-accelerated text (FreeType or multi-size atlas)
    Real shadows, rounded corners with proper AA, opacity
    Basic animation & spring system
    Theme system + dark/light mode
    Accessibility hooks (later)
    Component model + slots
    Simple routing / navigation stack

D. Development Workflow

nebula dev          # Opens Desktop window + hot reload (primary)
nebula dev --web    # Browser live reload
nebula run --android
nebula run --uefi
nebula build --target=bare-metal

Developers almost never need to test on bare-metal during normal UI work.
4. Implementation Roadmap (Practical)

Phase 1 — Foundation (Highest Priority)

    Stabilize and formalize the Scene Graph (output of layout)
    Introduce dual renderer interface
    Keep current software renderer working
    Make SDL2 the default modern backend with dirty regions

Phase 2 — Modern Quality

    Multi-size font system
    Proper text shaping
    Shadows + opacity + clipping
    Basic animation system
    Component model

Phase 3 — Platform Expansion

    Polish Android / iOS via SDL2
    Browser backend (WebGPU preferred)
    TV / embedded Linux targets

Phase 4 — Extreme Targets

    Improve software renderer quality
    Better freestanding allocator
    Input on UEFI / bare-metal

5. Why This Design Is Superior
Concern	Old Design	New Design
Layout consistency	Good	Guaranteed
Development speed	Slow (bare-metal focus)	Fast (Desktop/Browser)
Visual quality on phones/TVs	Limited	Modern
Performance	Software only	GPU where available
Bare-metal support	Excellent	Still excellent (fallback)
Long-term maintainability	Risky	Clear separation of concerns
Final Verdict

Pixel-identicality was never the real requirement.
Identical layouts + high visual quality on modern platforms + ability to still run on extreme hardware is the correct goal.

This revised architecture delivers exactly that.

6. Status (2026-09-08)

proposal-v4-renderer-architecture.md turned this roadmap into a concrete,
sequenced set of steps (A-I) and is the up-to-date source for what actually
shipped and why -- this section is a cross-check of THIS document's own
phase list against the repo as it stands, so a future contributor does not
have to re-derive it from source. "Done" below means implemented AND
verified (a passing check in verified-examples/), not just present.

Phase 1 -- Foundation
    Scene graph: DONE (toolkit/render/scene.tr; step C).
    Dual renderer interface: the software renderer is the only one that
      exists, by design -- the "Modern Renderer" (SDL_GPU/WebGPU) half of
      this item is proposal-v4 step H, deliberately DEFERRED after being
      measured (see proposal-v4 5a): current SDL2 rendering is already
      hardware-accelerated, a streaming-texture GPU path measured 1.8x
      SLOWER than the existing per-pixel draws, and rasterization is only
      48% of frame cost. Revisit if a workload appears the software path
      can't serve; nothing today qualifies.
    Software renderer kept working: DONE, continuously (every step this
      session re-verified subrect_render/diff_render/tailwind_layout).
    SDL2 as default + dirty regions: SDL2 canvas exists and scene-graph
      diffing exists and is verified (execute_diff, step I) -- but it is
      NOT wired into examples/widgets_demo's actual frame loop. That loop
      calls canvas.clear() then render_to() (full repaint) every frame,
      and separately host-paints several widgets (tabs, dropdown, slider,
      the header shadow) directly via raw Canvas calls outside the scene
      graph entirely. render_diff_to()'s own contract requires the caller
      to STOP clearing the canvas -- switching this one demo over means
      first bringing those host-painted widgets into the same
      paint-only-what-changed discipline, or accepting stale pixels under
      them. That is a real, separate scoped task, not a quick call-site
      swap; left open rather than attempted as a same-session rewrite of
      the flagship interactive demo.

Phase 2 -- Modern Quality
    Shadows: DONE (Canvas.draw_shadow, gated on Caps.shadows -- step B).
    Basic animation: DONE (Interpreter.anim_toward, generalizing
      Switch.tick()'s hand-rolled step-toward-target pattern to any node
      via its step-F identity; step G. Verified: animation.tr).
    Multi-size font system: DONE (2026-09-08). Three baked atlases
      (toolkit/text/font_data{,_sm,_lg}.tr -- 6x10/8x14/12x20 -- via
      scripts/bake-font.ps1's new -Suffix param), a Fonts holder
      (toolkit.text.font.Fonts) an Interpreter loads once and every text
      Cmd picks from by its own carried font_size, and a `text-sm`/
      `text-base`/`text-lg` style token. Layout (toolkit.layout.flex's
      glyph_w/glyph_h) and paint (execute_software/execute_diff) read the
      SAME per-node size so a line is never measured against one atlas and
      painted from another. Verified: multi_size_font.tr.
    Proper text shaping: NOT done, and not close -- the current text path
      is fixed-width glyph cells with no kerning, ligatures, or complex
      script support. A real shaping engine (even a minimal Latin-only
      kerning table) is a substantial standalone effort, deliberately left
      out of scope this session for that reason.
    Opacity: DONE (2026-09-08), narrower than a general alpha channel by
      design. Canvas gained `fill_rect_alpha(x,y,w,h,color,alpha)`; a
      backend that can genuinely blend (SdlCanvas -- real GPU blend via
      SDL_SetRenderDrawBlendMode; BufferCanvas -- real read-blend-write,
      since unlike firmware memory it already reads its own buffer back
      for to_ppm/get_px) does; a backend that cannot (FrameBuffer, GopCanvas,
      WebCanvas -- genuinely write-only or just not wired up yet) falls
      back to a safe opaque fill_rect, never a crash or corruption. An
      `opacity-N` style token, only honoured on a box's own PLAIN
      (radius<=0, unbordered) fill -- rounded/bordered opacity would need
      paint_rounded_rect_aa's per-pixel corner blends to ALSO factor in
      destination alpha, not attempted. Verified: opacity.tr.
    Clipping: DONE (2026-09-08). toolkit/render/clipped_canvas.tr's
      ClippedCanvas wraps any Canvas and intersects every fill_rect/
      set_pixel against its own rect -- nesting composes for free by
      wrapping a ClippedCanvas in another one, no explicit stack needed.
      A `clip` style token brackets a box's children (not the box's own
      background) with clip_push/clip_pop scene commands; execute_software
      walks them via RECURSION rather than a Canvas stack, since Canvas is
      an interface and Tauraro's generic List[T]/Array[T] storage cannot
      hold an interface's fat-pointer value directly (confirmed by trying
      it). render_diff() falls back to a full repaint whenever a scene
      contains any clip command (scene_has_clip) -- clip-aware diffing
      is a distinct, unattempted follow-up, not a correctness gap.
      Verified: clipping.tr.
    Component model: NOT done. Step F (node identity + persistent
      per-node state) is the prerequisite primitive a real component/slot
      abstraction would be built on, but no such abstraction exists yet --
      today's markup is still plain tag trees, not reusable authored
      components. Deliberately left for a future session: it is a real
      architecture decision (what does a "component" look like in this
      markup format, how do props/slots resolve) that deserves design time
      rather than a rushed pass, and by this point in the session every
      nebula build was taking 20-30+ minutes (all three baked font atlases
      now compile into every program that imports toolkit.ui.interp),
      making the kind of fast iterative refinement a new abstraction like
      this needs impractical to do responsibly in one more sitting.

Phase 3 -- Platform Expansion
    Android/iOS/TV via SDL2: not separately implemented because the
      design's own premise already covers it -- one SDL2 Canvas backend
      serves desktop and every SDL2-capable target identically (no
      per-platform nebula code exists to write). Genuine device/emulator
      QA on real mobile/TV hardware cannot be done from this development
      box and is out of scope here, not a code gap.
    Browser backend: DONE (toolkit/render/web/canvas.tr, WebCanvas --
      raw WASM-linear-memory buffer handed to JS via putImageData). This
      is the Canvas2D-style path this document itself listed as an
      acceptable alternative to WebGPU; WebGPU specifically is not
      implemented, consistent with proposal-v4's broader conclusion that
      GPU work isn't yet justified by any measured workload (5a).

Phase 4 -- Extreme Targets
    Software renderer quality: actively strong and still improving this
      session (AA rounded rects/borders/circles/text, drop shadows, scene
      diffing) -- an open-ended item by nature, not a checkbox to close.
    Freestanding allocator: DONE (toolkit/platform/arena.tr -- bump
      allocator with mark/release for per-frame reset).
    Input on UEFI/bare-metal: DONE (real GOP mouse+keyboard input,
      earlier session -- see project memory
      project_uefi_interactive_input_and_chrome).