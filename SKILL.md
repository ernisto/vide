---
name: vide
description: Write reactive Roblox UI with the Vide library (Solid-inspired Luau). Use when creating or editing UI components, sources/effects/derives, dynamic lists (indexes/values), show/switch control flow, springs, contexts, or create/mount instance trees in a Roblox Luau project that depends on vide (`centau/vide`). Triggers on vide.source, vide.create, vide.effect, source(), derive(), or files importing vide.
---

# Vide

Vide is a reactive Luau UI library for Roblox, inspired by SolidJS. UI is described declaratively; reactive **sources** drive **effects** that update instance properties automatically. No virtual DOM, no diffing — a source update reruns only the reactive scopes that read it.

## Mental model

Two scope kinds — get this right or reactivity misbehaves:

- **Stable scope** — never reruns. `root`, `mount`, `untrack`, `context`, and component bodies run here. Create UI instances here.
- **Reactive scope** — reruns when a source read inside it updates. `effect`, `derive`, and the dynamic scopes (`show`, `switch`, `indexes`, `values`, `spring`) run here.

Rules:
- A reactive scope **cannot** be created directly inside another reactive scope. (Nest via components / `untrack`, not raw `effect` inside `effect`.)
- **No yielding** in any scope (no `task.wait`, no yielding remotes). Strict mode errors on it.
- Destroying a scope destroys every scope created within it and runs its cleanups.
- Reading a source (`s()`) inside a reactive scope subscribes that scope. Reading via `untrack(s)` does not.

## Core primitives

```luau
local source = vide.source
local derive, effect, cleanup = vide.derive, vide.effect, vide.cleanup

local count = source(0)          -- Source<T>: count() reads, count(v) writes
count()                          -- 0
count(count() + 1)               -- set to 1

local doubled = derive(function() return count() * 2 end)  -- cached reactive value, read as doubled()

effect(function()                -- reruns whenever count() changes
    print(count())
    cleanup(function() print("before next run / on destroy") end)
end)
```

- Use `derive` (not a plain function) when a computed value is read multiple times between updates — it caches. A plain closure recomputes on every read.
- `cleanup(v)` accepts a function, thread, or object with `:destroy()`/`:disconnect()`. Runs before a rerun and on destruction.
- `batch(fn)` coalesces multiple source writes so dependent effects run once.
- `untrack(fn)` reads sources without subscribing.
- `read(v)` unwraps `T | () -> T` — use it in components that accept "value or source" props.

## Creating instances

`create` returns a constructor; call it with a property table. Property table rules:

```luau
local create = vide.create

create "TextButton" {
    Name = "Button",
    Size = UDim2.fromOffset(200, 60),

    Text = function() return "count: " .. count() end,  -- function (non-event) => bound via effect, updates reactively
    BackgroundColor3 = Color3.new(1,1,1),               -- plain value => set once

    Activated = function() count(count() + 1) end,      -- function on an event property => connected as callback

    create "UICorner" {},                                -- numeric index + instance => child
    function() return show(cond, Child) end,             -- numeric index + function => reactive children
}
```

- **String prop + function** = reactive binding (effect updates the property).
- **String prop that is an event** + function = event connection.
- **Numeric index** = child (instance, or function for reactive children, or a table to recurse).
- `create(existingInstance)` clones instead of `Instance.new`.

Mount a tree to a real instance:

```luau
local destroy = mount(App, game.StarterGui)   -- stable scope + parents result to target; call destroy() to tear down
-- or root(fn) -> (destroy, ...returns) when you don't need a parent target
```

## Components

A component is a plain function returning an instance. It runs in a stable scope. Accept sources for reactive inputs:

```luau
local function Button(props: { Text: () -> string, Activated: () -> () })
    return create "TextButton" {
        Text = props.Text,          -- pass the source through so the binding stays reactive
        Activated = props.Activated,
    }
end
```

Do **not** call `props.Text()` at the top of the component and pass the plain string — that freezes it. Pass the function through, or wrap: `Text = function() return read(props.Text) end`.

## Control flow & lists (dynamic scopes)

```luau
show(cond, Component)                 -- Component shown while cond() truthy; optional 3rd arg = fallback
show(cond, Component, Fallback)

switch(state) {                       -- pick Component by state() value from a map
    [true]  = function() return LoggedIn end,
    [false] = function() return LoggedOut end,
}

indexes(source_table, function(value, index)  -- one component per KEY; value is a Source, index is plain
    return Row { Text = function() return value().name end }
end)

values(source_table, function(value, index)   -- one component per VALUE; value is plain, index is a Source
    return Row { Text = function() return value.name end, Position = function() return posFor(index()) end }
end)
```

- `indexes` maps index→UI; value passed as a **source**, constructor not rerun when value changes. Prefer for primitive/stat lists.
- `values` maps value→UI; index passed as a **source**, good for reorderable/animated lists (players, inventory, chat). Values must be unique.
- All dynamic scopes return a source holding the current instance(s). Constructors may return a second number = seconds to delay destruction (exit transitions).

## Animation

```luau
local pos = spring(target_source, period, damping_ratio)  -- returns (source, control)
-- period: seconds per cycle (default 1); damping: 1 = critical, <1 overshoot, >1 slow
create "Frame" { Position = pos }
```

Springs step at 120Hz on Heartbeat. Call `vide.step(dt)` to drive manually (also stops the auto loop) — useful in tests.

## Context

```luau
local Theme = context()               -- or context(default)
root(function()
    Theme("dark", function()          -- provide value for this subtree
        Button()                      -- inside, Theme() reads "dark"
    end)
end)
```

Provider runs its inner function in a stable scope; consumers read with `Theme()`.

## Strict mode

`vide.strict = true` (auto-on when Luau optimization is off, e.g. tests) double-runs reactive scopes to catch non-idempotent effects and validates scope/yield/duplicate-value rules. **Effects must be idempotent** — writing UI is fine, but side effects like incrementing an external counter will fire twice. Develop with strict mode on.

## Common mistakes

- Reading a source once and passing the plain value where a source/function was expected → binding won't update. Pass the function.
- `effect` inside `effect` → error. Compose with components or `untrack`.
- Yielding inside a scope → error. Do async work outside, write results into a source.
- Using a plain function for a value read many times per frame → wrap in `derive` to cache.
- Forgetting `cleanup` for manual connections/instances created in an effect → leaks on rerun.

## Tips

- Prefer `vide.derive` over mutable `vide.source` for values computable from state. Never imperatively assign to a source that is part of a module's public API — expose it as a derive instead.
- Replace `vide.effect(function() local x = s(); if not x then return end ... end)` with `vide.show(s, function(x) ... end)`. Same applies to derives with a leading `if not state() then return nil end` guard.
- Use `vide.apply(instance) { Prop = source }` for property binding instead of a manual `vide.effect`.
- Use `vide.batch(fn)` when applying multiple source updates at once to avoid intermediate reactive recalculations.

## Reference

Full docs in `docs/api/` and the crash course in `docs/tut/crash-course/`. Internal reactive engine lives in `src/graph.luau`.
