# v4 architecture sketch (source for proposal-v4-renderer-architecture.md)

The original diagram this proposal was written from. Kept for provenance.

┌──────────────────────────────────────────────────────────────┐
│                     Application Layer                        │
│        .nbl markup + logic + components + routing            │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────────────────────────────────────────────────┐
│                 Nebula Core (Platform-Agnostic)               │
│                                                                │
│  • Markup Parser + Runtime Interpreter                        │
│  • Style System (Tailwind-compatible utility classes)         │
│  • Flexbox + Grid Layout Engine                                │
│  • Widget Tree + State Management                              │
│  • Event System + Hit Testing                                  │
│  • Animation & Transition System                                │
│  • Theme & Design Tokens                                        │
│  • Capability Flags (what THIS target's Renderer supports)      │
│                                                                │
│  Output: Scene Graph — rects, resolved styles, paint commands  │
└──────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                                │
┌─────────────▼─────────────┐    ┌─────────────▼─────────────┐
│   Modern Renderer          │    │   Extreme Renderer         │
│   (implements Renderer)    │    │   (implements Renderer)    │
│                             │    │                             │
│  • SDL2 / SDL_GPU           │    │  • Existing software        │
│    (Desktop, Mobile, TV)    │    │    rasterizer (proven,      │
│  • WASM build of the        │    │    freestanding-safe)       │
│    EXISTING rasterizer      │    │  • Runs on UEFI GOP,         │
│    (Browser, v1)            │    │    Cortex-M, custom          │
│  • WebGPU (Browser, v2,     │    │    framebuffers               │
│    opt-in upgrade path)     │    │                             │
│                             │    │  Guaranteed baseline +       │
│  Guaranteed baseline +      │    │  no enhancement (correctly   │
│  full progressive           │    │  declares its own            │
│  enhancement                │    │  capability flags)           │
└─────────────────────────────┘    └─────────────────────────────┘