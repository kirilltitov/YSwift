# YSwift

A Swift port of the necessary subset of [Yjs](https://github.com/yjs/yjs) for
**server-side Swift**, with **binary wire-compatibility with JS-Yjs** as the
number-one correctness requirement.

The required public API (requirements §4) is a single collaborative **text** type
per document, plus synchronization/encoding, sticky positions, awareness and
undo/redo. Container types (`Y.Map`/`Y.Array`/`Y.Xml*`) were originally out of
scope (§8) but have since been added as a **native-engine extension** — see
[`DECISIONS.md`](DECISIONS.md). Subdocuments remain out of scope.

## Status

The pure-Swift `NativeEngine` is the **default** backend; the Rust `YrsEngine`
stays as a differential oracle (`YSWIFT_ENGINE=yrs`). Implemented and verified
**byte-for-byte against JS-Yjs v13.6.31** on macOS + Linux:

- **Text** — insert/delete/format, `toDelta`, sync/encoding (`applyUpdate`,
  `encodeStateAsUpdate` full + diff, `encodeStateVector`), `YUpdate.merge/diff`,
  out-of-order pending buffer, sticky index, awareness, undo/redo, observers.
- **Containers** — `Y.Array`, `Y.Map`, `Y.Xml` (fragment/element/text): build,
  materialise, and byte-exact wire output.

Verification: golden vectors + concurrent convergence + a recorded randomised
differential fuzz (text/array/map) + adversarial code review, all green on both
engines. The default runtime path uses no Rust.

## Two-phase plan

The public API (in `Sources/YSwift`) is **frozen** and does not change between
phases. Only the internal engine behind it changes.

- **Phase 1 — facade over [Yrs](https://github.com/y-crdt/y-crdt) (Rust).**
  `YrsEngine` wraps `yrs` through its `yffi` C ABI. Yrs is already wire-compatible
  with Yjs, so Phase 1 inherits compatibility.
- **Phase 2 — native Swift.** A pure-Swift YATA + `lib0` implementation
  (`NativeEngine`) behind the same public API and producing the same bytes.

A single cross-implementation conformance suite (golden vectors from JS-Yjs)
gates both phases: Phase 2 is done when it passes exactly what Phase 1 passes.

## Current status

**Phase 1 complete** for the required subset. `YrsEngine` — a facade over Rust
`yrs` via the in-repo `cyrs` C ABI — backs the full §4 API: document + text
CRUD, `applyUpdate` / `encodeStateAsUpdate` / `encodeStateVector`, `onUpdate`
with transaction origins, `toDelta`, `YUpdate.merge` / `diff`, `StickyIndex`,
`Awareness`, `UndoManager`, and `text.observe`. A 25-test conformance suite
verifies byte-for-byte compatibility with **yjs v13.6.31** (updates, state
vectors, incremental updates, relative positions) plus structural `toDelta` and
behavioral undo/awareness/observe checks.

Phase 2 (a pure-Swift engine behind the same frozen API) is future work.

## Build

The Swift package links a Rust static library (`rust/cyrs`, a C-ABI facade over
`yrs`), so the staticlib must be built first. A Makefile chains the steps:

```sh
make build      # cargo build --release (cyrs) + swift build
make test       # + swift test (full conformance suite)
make rust-test  # cross-check yrs against the golden vectors
make fixtures   # regenerate golden vectors from pinned JS-Yjs
```

Prerequisites: a Swift 6.3+ toolchain and a Rust toolchain (`rustup`). Without
`make`, run `cargo build --release` in `rust/cyrs` before `swift build`/`swift test`.
