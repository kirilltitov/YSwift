# Decisions & open questions

Records the choices made while freezing the public API, including the §11 open
items from the requirements doc. Change these only deliberately — the public API
is a frozen contract across Phase 1 (Yrs facade) and Phase 2 (native Swift).

## Confirmed defaults (override if needed)

- **Wire format: v1.** Broadest compatibility; `bytea` in `crdt_update` is v1.
  Do not mix v1/v2 (requirements §9.2).
- **Phase-1 FFI mechanism: `yffi` C ABI + module map.** Cleanest for a Linux
  backend; UniFFI (`yswift`) is Apple-only/stale, `swift-bridge` adds tooling.
  A `CYrs` `systemLibrary` target will expose `libyrs.h`; `YrsEngine` wraps it.
- **Primary target: server (Linux).** Apple platforms supported as a bonus
  (`.macOS(.v15)`, `.iOS(.v18)` for `Synchronization.Mutex`).
- **`Y.Array` for child reorder: not now** (requirements §8 / §11) — the block
  tree lives in Postgres. Can be added later behind the same API.

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
- Update/awareness observer callbacks are `@Sendable` and are fired **outside**
  the transaction lock to avoid reentrancy/echo loops (requirements §9.3).

## Still open (confirm before Phase 1 wiring)

- Whether native Apple clients (iOS/macOS) also consume the port, which would
  raise the priority of API ergonomics there (requirements §11).
- Exact `yrs`/`yffi` version to pin so its v1 format matches the JS-Yjs version
  used by clients — must be verified empirically with golden vectors, not assumed.
