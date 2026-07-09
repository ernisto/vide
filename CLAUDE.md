# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Vide is a reactive Luau UI library for Roblox, inspired by [Solid](https://www.solidjs.com/). It is a library published to both [wally](wally.toml) (`centau/vide`) and [pesde](pesde.toml). It has no build step for development — source in `src/` is consumed directly.

## Commands

Toolchain is managed by [rokit](rokit.toml) (`rokit install` to fetch `luau`, `rojo`, `wally`, `pesde`). CI downloads a specific Luau release instead.

- **Run all tests:** `luau test/tests.luau` (exits non-zero on failure). This is the exact command CI runs.
- **Run a single test/case:** there is no CLI filter. Edit `test/tests.luau` and comment out the `TEST(...)` blocks you don't want, or temporarily narrow with the testkit `SKIP`/focus helpers in `test/testkit.luau`.
- **Type-check:** `luau-lsp analyze` or run through the editor; `.luaurc` sets `languageMode = "strict"`. Everything is expected to typecheck cleanly.
- **Build the rbxm** (release artifact): `rojo build default.project.json -o build.rbxm`.
- **Benchmarks:** `luau test/benchmarks.luau`.

### Tests run outside Roblox

Tests execute in plain Luau via the CLI, not in a Roblox DataModel. `test/mock.luau` provides fake `Instance`, `Signal`, `Vector2`, `UDim2`, etc. Source files detect the environment with the global `game` (e.g. `local Instance = game and Instance or require "../test/mock".Instance`) — when adding code that touches Roblox globals, keep this `game and ... or mock` pattern so tests still run.

`test/tests.luau` requires the library as a **consumer** via `require "../../vide"`: because the repo folder is itself named `vide`, `../../vide` resolves back to the repo's `init.luau`. It reaches into internals with `require "../../vide/src/graph"`. The repo must therefore sit in a parent directory for tests to resolve.

## Architecture

The whole library is assembled in [src/lib.luau](src/lib.luau) — the public surface, flag metatable, and the `Heartbeat` step loop that drives springs/timeouts. [init.luau](init.luau) just re-exports it. Start there to see what's exported.

### The reactive graph is the core

[src/graph.luau](src/graph.luau) is the heart of everything and the file to understand first. All reactivity is built on a single node/scope model:

- **Source nodes** (`create_source_node`) hold a value and a list of dependent children. Created by `source`.
- **Reactive nodes** (`create_node`) have an `effect` function, `owner`/`owned` (ownership tree for cleanup), and `parents` (the sources they read). Created by `derive`, `effect`, and the dynamic scopes.
- A **scopes stack** tracks the currently-running reactive scope. When a source is read (`read.luau`), the active scope is registered as a child of that source via `push_child`, building the dependency edges automatically. `pushing_parent_index` tracks which parents were touched this run so unused edges are pruned (`unparent_unuseds`).
- **Updating:** writing a source calls `update_descendants`, which walks the `update_queue`, re-evaluates dependent nodes (`evaluate_node`), and only propagates further when a node's cached value actually changed. `batch` defers this.
- **Ownership vs. dependency are separate axes.** `owner`/`owned` is the cleanup tree (destroying a scope destroys everything it owns and runs cleanups); `parents`/children is the dependency graph. Don't conflate them.
- **Strict mode** (`flags.strict`) double-runs effects to surface non-idempotent code and adds ownership/scope assertions. It is enabled automatically when Luau optimization is off (see [src/flags.luau](src/flags.luau)) and via the `vide.strict` flag; expect tests to run in strict mode.

### Layers on top of the graph

- **Reactivity primitives:** `source`, `derive`, `effect`, `root`/`mount` (create a stable owner scope), `cleanup`, `untrack`, `batch`, `read`, `context`.
- **Dynamic scopes:** `switch`, `show`, `indexes`, `values`, `branch` — these create/destroy child scopes reactively for control flow and lists. `values` maps by value identity, `indexes` maps by index.
- **Instance creation:** `create.luau` builds Roblox instances; `apply.luau` applies a property table, wiring reactive values to properties via effects and connecting event callbacks. `defaults.luau` holds per-class default properties (gated by `flags.defaults`). `create` currently supports deprecated overloads (string class name, existing instance to clone) — see the `todo: remove support for different overloads` note.
- **Animation/scheduling:** `spring.luau` and `timeout.luau` return a `(value, update_fn)` pair; their `update_*` functions are called each frame from the `step` loop in `lib.luau`.
- **Actions:** `action.luau` and `changed.luau` are special property-table entries handled by `apply`.

### Flags

`vide.strict`, `vide.defaults`, `vide.defer_nested_properties`, and `batch` are runtime flags stored in [src/flags.luau](src/flags.luau) and exposed through a metatable on the `vide` table (reads/writes go through `flags`). Setting an unknown flag errors.

## Conventions

- `snake_case` for internal identifiers; public API mirrors the docs. Files are single-responsibility, one primitive per file, wired together only in `lib.luau`.
- Everything must pass strict typechecking; internal `graph.luau` types (`Node<T>`, `SourceNode<T>`) are widely reused — prefer them over redefining.
- User-facing docs live in `docs/` (VitePress). Update `docs/api/*` and the crash course when changing public behavior, and add a `CHANGELOG.md` entry.
