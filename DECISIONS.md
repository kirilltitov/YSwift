# Decisions & open questions

Records the choices made while freezing the public API, including the §11 open
items from the requirements doc. Change these only deliberately — the public API
is a frozen contract across Phase 1 (Yrs facade) and Phase 2 (native Swift).

## Confirmed defaults (override if needed)

- **Wire format: v1.** Broadest compatibility; `bytea` in `crdt_update` is v1.
  Do not mix v1/v2 (requirements §9.2).
- **Phase-1 backend: an in-repo `cyrs` C-ABI crate over `yrs` 0.27.2** (built with
  the `sync` feature for a `Send`/`Sync` `Doc`, and `OffsetKind::Utf16` for yjs
  byte-compat). Chosen over yffi/UniFFI/swift-bridge for a minimal, controllable
  surface. The `CYrs` `systemLibrary` target exposes a hand-written `cyrs.h`;
  `YrsEngine` links `libcyrs.a` (on Linux also `-lpthread -ldl -lm`).
- **Primary target: server (Linux).** Apple platforms supported as a bonus
  (`.macOS(.v15)`, `.iOS(.v18)` for `Synchronization.Mutex`).
- **Container types (`Y.Array` / `Y.Map` / `Y.Xml*`): added as a native-engine
  extension** (beyond §8, on request). They live only behind `NativeEngine`
  (`YrsEngine` has trapping defaults — the `cyrs` FFI never wired them), so the
  public `YArray`/`YMap`/`YXmlFragment` require the native default engine. Wire
  output is byte-exact with yjs; the XML API builds subtrees declaratively
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
  document (requirements §9.5). Both engines must honour this.
- The API is **synchronous** and transaction-scoped (`doc.transact { txn in … }`),
  mirroring Yjs/Yrs. `YTransaction` is **not** `Sendable` and must not escape the
  `transact` closure.
- Observer callbacks (`onUpdate` / `text.observe` / awareness `onChange`) are
  `@Sendable` and fire **synchronously during commit**, carrying the transaction
  origin for echo-loop avoidance (§9.3). They must not re-enter the document
  (no `transact` inside a callback).

## Pinned versions (verified)

- **yjs `13.6.31`** (golden-vector source) ↔ **yrs `0.27.2`** (`Cargo.lock`).
  Byte-for-byte v1 compatibility verified on macOS and Linux (Swift 6.3.3).

## Known limitations (Phase 1 / yrs backend)

- **Multi-attribute `format` byte order.** yrs holds a range's attributes in a
  `HashMap`, so the independent per-attribute format structs serialize in a
  different order than yjs (which uses object insertion order). The result is
  **semantically identical and converges** — yjs applies our updates and vice
  versa — but the raw bytes differ from yjs for a *single* `format` call carrying
  *multiple* attributes. Single-attribute formats are byte-identical.
  (Characterized by the `semantic` fixture.) **The native engine shares this
  limitation** for the same root cause — the public `Attributes` (and XML
  attribute) dictionaries are unordered, so a multi-attribute text `format` or
  XML element is serialised in sorted-key order: deterministic and convergent,
  byte-exact when the peer used the same order, a semantic match otherwise.
- `UndoManager` and `Awareness` are **not `Sendable`** (single-context helpers);
  wrap in an actor if shared across connections. Their raw handles free on
  release, which must not race the document's edit path.
- `YSwift.UndoManager` shadows `Foundation.UndoManager` — qualify when both are
  imported.

## Still open

- Whether native Apple clients (iOS/macOS) also consume the port (requirements
  §11) — affects how much Apple-platform API ergonomics matter.
