# Decisions & open questions

Records the choices made while freezing the public API, including the §11 open
items from the requirements doc. Change these only deliberately — the public API
remains the frozen contract established during the migration to native Swift.

## Confirmed defaults (override if needed)

- **Wire format: v1.** Broadest compatibility; `bytea` in `crdt_update` is v1.
  Do not mix v1/v2 (requirements §9.2).
- **Implementation: pure Swift.** `NativeEngine` implements YATA and the
  `lib0` v1 codec in-tree. The package has no C ABI, Rust toolchain, or native
  linker dependency. The former `yrs` facade is preserved separately on the
  [`engine/yrs` maintenance branch](https://github.com/kirilltitov/YSwift/tree/engine/yrs).
- **Primary target: server (Linux).** Apple platforms supported as a bonus
  (`.macOS(.v15)`, `.iOS(.v18)` for `Synchronization.Mutex`).
- **Container types (`Y.Array` / `Y.Map` / `Y.Xml*`): added to the native
  implementation** (beyond §8, on request). Wire output is byte-exact with yjs
  except for the documented semantically equivalent multi-attribute key-order
  case; the XML API builds subtrees declaratively
  (`YXmlNode`). Subdocuments remain out of scope. Not yet: `YXmlHook`, mutating an
  already-integrated XML node, nested containers *as values* inside array/map
  (materialisation skips `ContentType`), container `observe` events.

## Idiomatic upgrades over the requirements' approximate signatures

- **`[String: Any]` → `YValue` (a `Sendable` JSON-like enum), `Attributes = [String: YValue]`.**
  `Any` is not `Sendable` (breaks the concurrency model) and a typed value model
  is required anyway to reproduce `lib0`'s byte-exact `any` encoding.
- **`Origin` is a `Sendable` value type** (wraps a `String`), not `Any` — so it
  is usable in `Set<Origin>` (undo tracked-origins) and crosses isolation safely.
- **`captureTimeout: Duration`** (not a millisecond number) on `UndoManager`.
- **`StateVector` is a distinct wrapper type** around `Data`, so an update and a
  state vector cannot be accidentally interchanged.

## Concurrency model (frozen)

- `YDoc` is a `final class`, `Sendable`, and **serializes transactions** with an
  internal `Mutex` (Synchronization) — at most one active write transaction per
  document (requirements §9.5).
- The API is **synchronous** and transaction-scoped (`doc.transact { txn in … }`),
  mirroring Yjs. `YTransaction` is **not** `Sendable` and must not escape the
  `transact` closure.
- Observer callbacks (`onUpdate` / `text.observe` / awareness `onChange`) are
  `@Sendable` and fire **synchronously during commit**, carrying the transaction
  origin for echo-loop avoidance (§9.3). They must not re-enter the document
  (no `transact` inside a callback).

## Pinned compatibility target

- **yjs `13.6.31`** is the golden-vector source. Byte-for-byte v1
  compatibility is verified on macOS and Linux (Swift 6.3.3).

## Known limitations

- **Multi-attribute `format` byte order.** The public `Attributes` (and XML
  attribute) dictionaries are unordered, so a multi-attribute text `format` or
  XML element is serialised in sorted-key order. The result is deterministic
  and convergent, byte-exact when the peer used the same order, and otherwise a
  semantic match. Single-attribute formats are byte-identical. This is
  characterised by the `semantic` fixture.
- `UndoManager` and `Awareness` are **not `Sendable`** (single-context helpers);
  wrap in an actor if shared across connections.
- `YSwift.UndoManager` shadows `Foundation.UndoManager` — qualify when both are
  imported.

## Still open

- Whether native Apple clients (iOS/macOS) also consume the port (requirements
  §11) — affects how much Apple-platform API ergonomics matter.
