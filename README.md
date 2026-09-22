# YSwift

A Swift port of the necessary subset of [Yjs](https://github.com/yjs/yjs) for
**server-side Swift**, with **binary wire-compatibility with JS-Yjs** as the
number-one correctness requirement.

The original required public API (requirements §4) is a single collaborative
**text** type per document, plus synchronization/encoding, sticky positions,
awareness and undo/redo. Container types (`Y.Map`/`Y.Array`/`Y.Xml*`) were
originally out of scope (§8) but have since been added to the pure-Swift
implementation — see [`DECISIONS.md`](DECISIONS.md). Subdocuments remain out
of scope.

## Status

YSwift is a **pure-Swift** YATA + `lib0` implementation with no Rust runtime or
build dependency. It is implemented and verified against **JS-Yjs v13.6.31**
on macOS + Linux, byte-for-byte except for the documented semantically
equivalent multi-attribute key-order case:

- **Text** — insert/delete/format, `toDelta`, sync/encoding
  (`applyUpdateChecked`, legacy `applyUpdate`, `encodeStateAsUpdate` full + diff,
  `encodeStateVector`), `YUpdate.merge/diff`, out-of-order pending buffer,
  sticky index, awareness, undo/redo, observers.
- **Containers** — `Y.Array`, `Y.Map`, `Y.Xml` (fragment/element/text): build,
  materialise, and compatible wire output, subject to the same documented
  multi-attribute key-order exception.

Verification: golden vectors + concurrent convergence + a recorded randomised
differential fuzz (text/array/map) + adversarial code review. The public surface
is gated directly against Yjs fixtures and convergence scenarios.

### Document-less update limits

`YUpdate.merge` and `YUpdate.diff` throw `YError.causalDependenciesMissing` when
an input depends on structures or deletions absent from the supplied updates.
These helpers compact causally complete inputs; they do not implement Yjs's
arbitrary partial-update wire merge. Invalid inputs throw `YError.invalidUpdate`.

When a caller owns the baseline document, apply the changes to that document and
use `encodeStateAsUpdate` with its previous state vector. This preserves deleted
items and the identities needed by later input. `YUpdateCausalClosureTests`
covers partial insertion, partial deletion, compensation, and late input.

The former Rust/`yrs` differential oracle remains available on the
[`engine/yrs` maintenance branch](https://github.com/kirilltitov/YSwift/tree/engine/yrs).
It is intentionally not part of `main` or the published pure-Swift package.

### Safe v1 update ingress

Use `YDoc.applyUpdateChecked` at every external update boundary. It calls
`YUpdate.validateV1` before integration, then maps structural and integration
failures to `YError.invalidUpdate`:

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
  particular document.
- Application is conservatively documented as non-rollback-atomic. If checked
  application throws, discard the candidate document; do not inspect, persist,
  or reuse it.

The legacy `applyUpdate` wrapper runs the same checks but intentionally swallows
the error to preserve its original nonthrowing signature. It cannot tell the
caller whether application succeeded and retains the same late-error
partial-prefix risk. Keep it only for source compatibility; new ingress code
must use the checked API and the disposable-document pattern above.

The checked v1 profile caps clocks and lengths at the implementation's supported
limit (`UInt32.max`). Dynamic `Any` objects with duplicate keys or
`__proto__` are rejected recursively because JavaScript and Swift otherwise
materialise those wire values differently. JSON syntax follows `JSON.parse`,
including escaped unpaired UTF-16 surrogates; YSwift preserves those escapes
byte-for-byte.

Transaction origin is fixed when `transact(origin:_:)` opens the transaction and
is forwarded to update observers. The source-compatible `origin` arguments on
`applyUpdate` and `applyUpdateChecked` do not retag an already-open transaction.

Text insertion also distinguishes an omitted attributes argument from an
explicitly empty dictionary. `attributes: nil` inherits the active formatting at
the insertion point, while `attributes: [:]` inserts unformatted text and then
restores the surrounding format.

## Implementation

The original two-phase migration is complete. `main` ships one implementation:

- **`NativeEngine`** — the completed pure-Swift YATA + `lib0`
  implementation behind the public `YDoc` API, including array, map, and XML
  extensions.

Golden-vector and public-behavior suites verify text updates, state vectors,
incremental updates, relative positions, deltas, origin propagation, undo,
awareness, observers, checked ingress, and wire compatibility with **Yjs
v13.6.31**.

## Build

YSwift is a regular Swift package:

```sh
swift build
swift test
swift run YSwiftBench

# Equivalent convenience targets:
make build
make test
make fixtures   # regenerate golden vectors from pinned JS-Yjs (requires Node.js)
```

The only build prerequisite is a Swift 6.3+ toolchain. Node.js is needed only
when regenerating the checked-in Yjs fixtures.
