# YSwift

A Swift port of the necessary subset of [Yjs](https://github.com/yjs/yjs) for
**server-side Swift**, with **binary wire-compatibility with JS-Yjs** as the
number-one correctness requirement.

The public API is intentionally small: a single collaborative **text** type per
document, plus synchronization/encoding, sticky positions, awareness and
undo/redo. Container types (`Y.Map`/`Y.Array`/`Y.Xml*`) and subdocuments are
**out of scope** — see [`DECISIONS.md`](DECISIONS.md).

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

**Scaffold.** The public API is defined and compiles; the engine is a stub
(`UnimplementedEngine`) that traps on any operation touching CRDT state. Next
step: wire `YrsEngine` over `yffi`.

## Build

```sh
swift build
swift test
```

Requires a Swift 6.3+ toolchain.
