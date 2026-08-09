# YSwift

A Swift port of the necessary subset of [Yjs](https://github.com/yjs/yjs) for
**server-side Swift**, with **binary wire-compatibility with JS-Yjs** as the
number-one correctness requirement.

The original required public API (requirements §4) is a single collaborative
**text** type per document, plus synchronization/encoding, sticky positions,
awareness and undo/redo. Container types (`Y.Map`/`Y.Array`/`Y.Xml*`) were
originally out of scope (§8) but have since been added as a **native-engine
extension** — see [`DECISIONS.md`](DECISIONS.md). Subdocuments remain out of
scope.

## Status

The pure-Swift `NativeEngine` is the **default** backend; the Rust `YrsEngine`
stays as a differential oracle (`YSWIFT_ENGINE=yrs`). Implemented and verified
**byte-for-byte against JS-Yjs v13.6.31** on macOS + Linux:

- **Text** — insert/delete/format, `toDelta`, sync/encoding
  (`applyUpdateChecked`, legacy `applyUpdate`, `encodeStateAsUpdate` full + diff,
  `encodeStateVector`), `YUpdate.merge/diff`, out-of-order pending buffer,
  sticky index, awareness, undo/redo, observers.
- **Containers** — `Y.Array`, `Y.Map`, `Y.Xml` (fragment/element/text): build,
  materialise, and byte-exact wire output on the native engine.

Verification: golden vectors + concurrent convergence + a recorded randomised
differential fuzz (text/array/map) + adversarial code review. The shared public
surface is gated with both engine selections; native-only containers are gated
directly against Yjs fixtures and convergence scenarios. The default runtime
path uses no Rust.

### Safe v1 update ingress

Use `YDoc.applyUpdateChecked` at every external update boundary. It calls
`YUpdate.validateV1` before entering the selected backend, then maps both
structural and backend failures to `YError.invalidUpdate`:

```swift
do {
    try candidate.transact(origin: "remote") { txn in
        try candidate.applyUpdateChecked(txn, update)
    }
} catch {
    candidate.destroy()
    throw error
}
```

Here `candidate` must be a disposable document (normally seeded from the last
trusted state), promoted only after the operation succeeds. Validation and
application are deliberately separate guarantees:

- `YUpdate.validateV1` is a document-less structural preflight. It accepts
  exactly one complete v1 update and rejects trailing bytes, non-canonical or
  overflowing integers, invalid UTF-8/JSON, unsafe declared sizes, invalid
  control values, duplicate dynamic-object keys and `__proto__`.
- Structural success does **not** prove that references are causally usable by a
  particular document or that every backend can materialise every legal value.
- Backend application is not rollback-atomic. In particular, yrs may discover
  a semantic error after integrating a valid prefix. If checked application
  throws, discard the candidate document; do not inspect, persist, or reuse it.

The legacy `applyUpdate` wrapper runs the same checks but intentionally swallows
the error to preserve its original nonthrowing signature. It cannot tell the
caller whether application succeeded and retains the same late-error
partial-prefix risk. Keep it only for source compatibility; new ingress code
must use the checked API and the disposable-document pattern above.

The checked v1 profile caps clocks and lengths at the shared native/yrs limit
(`UInt32.max`). Dynamic `Any` objects with duplicate keys or `__proto__` are
rejected recursively: JavaScript, Swift and Rust otherwise materialise those
wire values differently. JSON syntax follows `JSON.parse`, including escaped
unpaired UTF-16 surrogates. `NativeEngine` preserves those escapes byte-for-byte;
the optional `YrsEngine` rejects them because Rust strings cannot represent an
unpaired surrogate. This is a backend materialisation difference, not a
structural-validation failure.

Transaction origin is fixed when `transact(origin:_:)` opens the transaction and
is forwarded to update observers. The source-compatible `origin` arguments on
`applyUpdate` and `applyUpdateChecked` do not retag an already-open transaction.

Text insertion also distinguishes an omitted attributes argument from an
explicitly empty dictionary. `attributes: nil` inherits the active formatting at
the insertion point, while `attributes: [:]` inserts unformatted text and then
restores the surrounding format. Both engines implement this Yjs distinction.

## Engines

The original two-phase migration is complete. The public API is shared by two
selectable engines:

- **`NativeEngine` (default)** — the completed pure-Swift YATA + `lib0`
  implementation. It also implements the native-only array, map, and XML
  extensions.
- **`YrsEngine` (oracle)** — the original facade over
  [yrs](https://github.com/y-crdt/y-crdt) through the in-repo `cyrs` C ABI. Set
  `YSWIFT_ENGINE=yrs` before constructing a document to select it for
  differential verification. Container extensions are not wired through this
  FFI backend.

Golden-vector and public-behavior suites verify text updates, state vectors,
incremental updates, relative positions, deltas, origin propagation, undo,
awareness, observers, checked ingress, and engine parity against **Yjs
v13.6.31**.

## Build

The Swift package links a Rust static library (`rust/cyrs`, a C-ABI facade over
`yrs`), so the staticlib must be built first. A Makefile chains the steps:

```sh
make build      # cargo build --release (cyrs) + swift build
make test       # + swift test (NativeEngine default)
YSWIFT_ENGINE=yrs make test  # repeat the public suite through YrsEngine
make rust-test  # cross-check yrs against the golden vectors
make fixtures   # regenerate golden vectors from pinned JS-Yjs
```

Prerequisites: a Swift 6.3+ toolchain and a Rust toolchain (`rustup`). Without
`make`, run `cargo build --release` in `rust/cyrs` before `swift build`/`swift test`.
