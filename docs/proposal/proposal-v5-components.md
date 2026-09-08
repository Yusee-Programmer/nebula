# Proposal v5 — Component model + SPA navigation

**Status:** implemented 2026-09-08. Closes the one open item proposal-v4 §9
called out by name: "State management (F) is the highest-value item in the
sketch" — components are what F was *for* — and nebula1.0.md §3C's "simple
routing / navigation stack" (§9).

---

## 1. The one-sentence version

A component is a `.ui` markup template with `<slot .../>` placeholders for
children and `{name}` placeholders for props; `instantiate()` turns one,
given props and slot contents, into a fresh `Pointer[UiNode]` subtree that
splices into a parent exactly like any hand-built node — because that's all
it is by the time layout sees it.

## 2. Why this shape, and not a parser change

Two things turned out to already be true, and they're what make this a
library-level addition rather than a grammar change:

- **The parser is already tag-name-agnostic.** `parse_element()` never
  checks `tag` against a built-in list — `<Card ...>` parses today, with
  zero changes, into `UiNode.Element("Card", ...)` exactly like `<panel>`
  does. There was never a closed set of tags to extend.
- **Layout dispatches on the `Element`/`Text` enum variant, never on the tag
  string.** `flex.tr build()`'s `match` has exactly two live arms. A tag
  is a label carried through to `LayoutBox.tag` for painting/debugging; it
  drives no layout behavior.

So a component system can be a pure tree-transform that runs *before*
`layout_tree()`, and every one of the toolkit's existing guarantees —
`Canvas` doesn't change (step C's rule), `node_key` positional identity
doesn't change (step F), scene diffing doesn't change (step I) — holds
by construction, not by careful case analysis. `toolkit/ui/component.tr`
imports `toolkit.ui.ast` and nothing else touches it.

## 3. Slots

```
<slot/>              default slot, name ""
<slot "header"/>      named slot "header"
```

A slot's name is carried in the *class-string* field, not a new attribute —
the same trick `key-<name>` already uses on `node_key` (§ flex.tr). This
was the deciding reason named slots cost nothing extra in grammar terms:
`<slot "header"/>` parses today with the existing one-bare-string-per-tag
rule, so "named slots from day one" and "single default slot" turned out to
be the same amount of parser work (zero) — the only real cost is in
`instantiate()`'s bookkeeping, which is a `Dict[str, List[Pointer[UiNode]]]`
either way.

An unfilled slot expands to nothing (no fallback content in v1) — a
component author who wants a default should check for it in the props/host
code that calls `instantiate()`, not in the template.

## 4. Props

`{name}` tokens inside a template's class strings and `<text>` bodies are
replaced from a `Dict[str, str]` via `Str.replace` per prop — literal
substring replacement, no expression language, no conditionals. This is
deliberately as small as the "trust boundary" comment atop `parser.tr`
implies markup should stay: a component's *structure* (how many children,
what layout) is fixed at template-authoring time; only leaf strings vary
per use. Reordering/conditional structure per use is a host-code decision
(build a different template, or compose `instantiate()` results in host
code) — not attempted here, matching how `tab_trees` already works in
`widgets_demo`.

## 5. API

```
toolkit/ui/component.tr

pub def instantiate(
    template: Pointer[UiNode],
    slots:    Dict[str, List[Pointer[UiNode]]],
    props:    Dict[str, str],
) -> Pointer[UiNode]

pub def one_slot(children: List[Pointer[UiNode]]) -> Dict[str, List[Pointer[UiNode]]]
    # shorthand for the common single-default-slot case: { "": children }

pub def no_props() -> Dict[str, str]
    # shorthand for a component instantiated with no prop substitution
```

Usage (host Tauraro code — the same shape `widgets_demo` already uses for
`tab_trees`, just with a template parsed once and instantiated per use):

```
mut card_tpl = parse_ui(CARD_SRC)     # parse once (startup, or cached)

mut props: Dict[str, str] = {}
props["title"] = "Settings"

mut body: List[Pointer[UiNode]] = [some_text_node]
mut card = instantiate(card_tpl, one_slot(body), props)

# splice `card` into the parent's own children list before boxing the
# parent -- exactly like any node the parser or `new_element` produced.
```

## 6. Identity and state — why nothing else changes

`instantiate()` returns before `layout_tree()`/`build()` ever runs. By the
time `build()` walks the tree, a component instance is structurally
indistinguishable from hand-written markup at that position: same two enum
variants, same positional `path`, same `key-<name>` override rule. Two
`instantiate()` calls of the same template at two different structural
positions in the parent get different positional `node_key`s automatically
(different `path` strings), exactly as two literal copy-pasted `<panel>`
blocks would. No change to `flex.tr`, `interp.tr`, or `scene.tr` was
needed, and none was made.

One consequence worth stating precisely: if a template uses the *same*
`<slot/>` name twice, both occurrences splice the *same* `Pointer[UiNode]`
children by reference into two different structural parents. This is safe
— nothing downstream mutates a `UiNode` after it is built — but it does
mean the two occurrences are not independent copies for identity purposes
in the way a caller might assume; not a concern for the templates this
session needed, worth a doc comment where it matters.

## 7. What this deliberately does not do

- No markup-level invocation syntax (`<Card title="x">...</Card>` calling
  a registered builder automatically). `instantiate()` is a host-code call.
  Adding sugar for it is a real parser change — routing an unrecognized tag
  to a registered component function, deciding whether/how children get
  attributed to a named vs. default slot from markup alone — and is exactly
  the kind of "real architecture decision" nebula1.0.md §6 flagged as
  needing its own design time, deferred rather than folded in here.
- No fallback/default slot content, no conditional structure, no loops
  inside a template. Matches §4's "leaf strings vary, structure doesn't."
- No caching of `instantiate()` results — every call allocates a fresh
  subtree, same cost shape as `layout_tree()` already rebuilding every
  frame, covered by the same per-frame arena reset (Phase 1).

## 8. Verification

`verified-examples/component_model.tr` — a `Card` template with a `{title}`
prop, a named `"header"` slot and a default slot, instantiated twice with
different props/children at different tree positions. Checks: prop
substitution reaches both a class string and a text body; an unfilled named
slot contributes zero nodes and does not crash; default-slot children are
spliced in the right position; the two instances get distinct positional
`node_key`s; a template with no slots at all still round-trips unchanged.

---

## 9. Navigation — SPA-style pages on top of the same mechanism

nebula1.0.md's own architecture sketch (§3C) lists "simple routing /
navigation stack" as a Must Have; this closes it, in the same additive,
nothing-else-changes way as §§1–8: a page IS a component, and route params
ARE props, so no new substitution mechanism was needed — only bookkeeping
for "which page is current" and "how did we get here."

### 9.1 Router

```
toolkit/ui/router.tr

pub class Route:
    pub name:     str
    pub template: Pointer[UiNode]

pub class Router:
    pub routes:       List[Route]
    pub current:      str
    pub params:       Dict[str, str]
    pub history:      List[str]
    pub hist_params:  List[Dict[str, str]]

pub def register(r: Router, name: str, template: Pointer[UiNode]) -> void
pub def navigate(r: Router, name: str, props: Dict[str, str]) -> void
    # pushes (current, params) onto history, then switches to (name, props)
pub def back(r: Router) -> bool
    # pops history; false (no-op) if there is nowhere to go back to --
    # so a Back button's own enabled state is `router.can_back()`
pub def can_back(r: Router) -> bool
pub def page(r: Router, slots: Dict[str, List[Pointer[UiNode]]]) -> Pointer[UiNode]
    # instantiate()s the current route's template with the current params
```

A page's route params flow through the exact `instantiate()` props path
component props already use — `/user/{id}`-style params and a component's
own `{title}` are the same substitution, just populated from different call
sites (`navigate()` vs. a direct `instantiate()` call).

### 9.2 Wiring a navigation

No new event mechanism either. A "Go to Settings" button's handler is an
ordinary `EventHandler` (the same allowlist `register_handler` already
uses, the same shape as `desktop.tr`'s `Say` handler) whose `call()` holds
a reference to the `Router` and calls `navigate(router, "settings", {})`.
`toolkit.ui.interp` was not touched to add this — routing is host-code
composition on top of a mechanism (named handlers, `instantiate()`) that
already existed.

Per-frame shape, host-owned like everything above `Canvas`:

```
mut page_tree = page(router, one_slot([]))
mut full = instantiate(shell_tpl, one_slot([page_tree]), no_props())
render_to(it, full, canvas)
```

`shell_tpl` is an ordinary component template with a persistent nav bar and
a `<slot/>` where the current page lands — a page swap is just a different
`Pointer[UiNode]` being spliced into the same slot position next frame.

### 9.3 The state-namespacing caveat — read before shipping a stateful page

`node_key` (step F) is **purely positional**: `flex.tr build()` threads the
structural `path` string into children regardless of any `key-<name>`
override on an ancestor (the override replaces that ONE node's own key; it
is not a prefix children inherit). So if `home_tpl` and `settings_tpl` both
happen to put, say, a collapsible panel as their second child, that panel
gets the SAME `node_key` in both pages, because both are spliced into the
identical slot position. Navigating `home` → `settings` will show
`settings`'s panel initially reflecting whatever `Interpreter.state` was
last written under that shared key by `home`'s panel — a one-frame-visible
stale value, not a crash or corruption (unseen keys already default
safely), but a real, visible bug for any page with meaningfully different
per-position stateful widgets.

**This was left unsolved on purpose rather than patched into `flex.tr`.**
Threading a per-route namespace prefix into `build()`'s `path` is a real,
surgical option (`layout_tree` would need an optional prefix parameter) but
it is a change to the step-F identity mechanism itself, and every page in
the app pays a rebuild the moment that changes — exactly the kind of
backend-boundary change §§1–8 went out of their way to avoid for
components. The cheap, already-existing escape hatch: a page template that
has stateful widgets gives them explicit `key-<routename>-...` tokens (the
same mechanism a reordering list already needs), which guarantees no
collision with any other route. `home.ui`/`settings.ui` in
`verified-examples/router_nav.tr` do exactly this.

### 9.4 What this deliberately does not do

- No URL bar / browser History API integration on the web target. Desktop
  and bare-metal have no URL to sync to anyway; wiring `WebCanvas` to
  `history.pushState` is a real, separately-scoped follow-up if the web
  target specifically needs deep-linking, not attempted here.
- No route matching beyond an exact name (no `/user/:id` path patterns,
  no wildcards). `navigate("user", props)` with `props["id"] = "42"` is the
  v1 shape; a path-pattern parser is easy to add later without touching
  this section's API if it turns out to be needed.
- No guard/redirect hooks (auth-gated routes, etc.) — `navigate()` always
  succeeds. Host code can check a condition before calling `navigate()`
  today; a formal guard hook is deferred until a real use needs it.

### 9.5 Verification

`verified-examples/router_nav.tr` — two routes (`home`, `settings`)
registered on a `Router`, navigated between (forward and `back()`), with
route params substituted into each page's title. Checks: `current`/`params`
update on `navigate()`; `history` grows and `back()` restores the prior
route+params in order; `can_back()` is false with empty history and true
after at least one `navigate()`; a shell template's `<slot/>` receives
whichever page is current at the moment `page()` is called; and the §9.3
caveat itself — two pages sharing a positional slot for a stateful widget
DO show the collision when neither uses an explicit key, and do NOT when
both use `key-<routename>-...`, proving the escape hatch actually closes
the gap it claims to.
