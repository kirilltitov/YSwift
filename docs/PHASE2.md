# Phase 2 — native Swift engine

Phase 1 shipped a working, conformance-verified library backed by Rust `yrs`
(`YrsEngine`). Phase 2 replaced that backend with a **pure-Swift
`NativeEngine`** behind the **same frozen public API**, then extended it to the
rest of Yjs.

This document records that migration. The completed `main` branch now contains
only the native implementation. The former Rust oracle is preserved on the
[`engine/yrs` maintenance branch](https://github.com/kirilltitov/YSwift/tree/engine/yrs).

## Historical migration strategy

`NativeEngine` was introduced behind the internal `YEngine` protocol so it
could be compared with the original `YrsEngine` while the port was built.
That temporary in-process oracle, together with JS-Yjs golden vectors, enabled
byte-for-byte checks and property-based convergence testing before the Rust
implementation was split from `main`.

Locked design decisions (from the feasibility analysis):

- **Arena / handle store**, not an ARC pointer graph. `StructStore` owns
  per-client arrays; `left`/`right`/`parent`/`origin` are IDs/indices resolved
  through the store. No retain cycles, cache-friendly, `Sendable`-clean.
- **Text as `[UInt16]`** (UTF-16 code units) — matches Yjs clock/length
  semantics; reproduce `ContentString`'s surrogate-split → U+FFFD guard.
- **`YValue` with ordered object pairs** for byte-exact `lib0` `any`.
- **`lib0` v1 codec, byte-exact.** V2 (RLE) is deferred to Task 2.
- **Target: yjs v13.6.31** (the source of the checked-in golden fixtures).
- Multi-attribute `format` remains a semantic fixture because Swift
  dictionaries do not preserve the caller's insertion order; the encoder uses
  deterministic sorted-key order.

`ycs` (C#) is a near-line-by-line v13 port with a bundled `lib0`; used as a
structural **reference map**, not copied.

## Status (current)

**Phase 2 is complete and `NativeEngine` is the sole implementation on
`main`.** The package has no Rust runtime or build dependency. It is verified
against JS-Yjs v13.6.31 on macOS + Linux, byte-for-byte except for the
documented semantically equivalent multi-attribute key-order case.

- **Task 1 (M1–M7): done.** Full §4 surface on the native engine — lib0 codec,
  arena store, YATA integrate/apply, encode (full + diff), out-of-order pending
  buffer, YText + `toDelta`, `onUpdate`+origin, `YUpdate.merge/diff`,
  `StickyIndex`, `Awareness`, `UndoManager`, `text.observe`.
- **Task 2 (partial): containers done** — `Y.Array`, `Y.Map`, `Y.Xml`
  (fragment/element/text): build, materialise, compatible wire with the noted
  multi-attribute key-order exception, concurrent convergence. **Not done:**
  subdocuments, snapshots, V2 format, deep observers, container `observe`,
  `YXmlHook`, mutating an already-integrated XML node.
- **Verification:** golden vectors + concurrent-convergence fixtures + a recorded
  randomised differential fuzz (text/array/map, applied in shuffled orders) +
  adversarial code review of the text engine and containers.
- **M8: done** — native benchmark harness (`Sources/YSwiftBench`) +
  optimisation (search-marker for text, skip-cleanup on read txns).

The milestone tables below are the original plan, kept for reference.

## Task 1 — native core + the current §4 API

| Milestone | Content | Verification gate |
|---|---|---|
| **M1. lib0 v1 codec** | `Encoder`/`Decoder` over bytes; `varUint`/`varInt` (to 2^53, sign/continuation, `-0`), `varString` (UTF-8), fixed uint8/16/32, **big-endian** float32/64, `writeAny`/`readAny` (tags 116–127, int→float32→float64 dispatch). | Golden byte-vectors generated from `lib0` (Node) round-trip byte-identically. |
| **M2. Structs + store** | `ID`, `AbstractStruct`, `GC`, `Skip`, `Item`, arena `StructStore` (`findIndexSS`, clean-split); content types (`ContentString` on `[UInt16]`, `ContentAny`/`JSON`/`Deleted`/`Format`/`Type`/`Binary`/`Embed`/`Doc`). | Decode a golden update → structs → re-encode byte-identically (no integration). |
| **M3. YATA integrate + apply** | `Item.integrate` (two-set resolver, clientID tie-break), `readUpdate`/`writeClientsStructs`, `DeleteSet` + apply, minimal `Transaction`. | `applyUpdate(golden)` → correct text + state vector; `golden-decode` green. |
| **M4. Round-trip + out-of-order** | `encodeStateAsUpdate` (full + since-SV), pending/retry buffer for out-of-order updates. | `golden-encode` (byte) + `convergence` green; native and JS converge under shuffled delivery. |
| **M5. YText + toDelta** | local `insert`/`delete`/`format` (`ItemTextListPosition`, format markers), `toString`, `toDelta` state machine, search-marker cache. | `golden-encode` + `toDelta` green; multi-attribute format converges with deterministic key order. |
| **M6. §4 surface** | `onUpdate` + transaction `origin`; `YUpdate.merge`/`diff`; `StickyIndex`; `Awareness`; `UndoManager`; `text.observe` (`YEvent`). | **All conformance tests** pass against `NativeEngine`. |
| **M7. Swap-in + fuzzing** | Make `NativeEngine` the package implementation; run property-based differential tests against the golden corpus and JS-Yjs. | Full public-API and wire parity; native implementation ready to replace the migration oracle. |

## Task 2 — remaining Yjs (additive; extends §4 without breaking it)

- Container types: `Y.Map`, `Y.Array` (+ `Y.Array.move`), then `Y.Xml*`.
- Subdocuments (`ContentDoc`, subdoc lifecycle, `whenLoaded`/`whenSynced`).
- Snapshots (`Snapshot` = state vector + delete set; restore; `gc:false`).
- V2 update format (RLE codec family) + V1↔V2 conversion, `updateV2` events.
- Deep observers (`observeDeep`, `YEvent.path`/`keys`/`delta`).
- Full relative/absolute positions, `PermanentUserData`.

## M8 — benchmarks & optimization (final phase)

1. **Benchmark harness** (dev-only dependency, e.g. `ordo-one/package-benchmark`
   or a `ContinuousClock` micro-harness): scenarios mirroring `crdt-benchmarks`
   — sequential insert, random insert, large-doc load/encode/decode, apply-sync,
   concurrent merge. Track native results and compare externally with JS-Yjs
   when useful.
2. **Profile-guided optimization rounds** (Instruments on macOS, `perf` on
   Linux): target the search-marker cache, arena access, `[UInt16]` splicing,
   allocation churn in encode/decode (`reserveCapacity`, `Span`/`RawSpan`,
   `~Copyable`/`InlineArray` where it pays).
3. Track results in this doc; guard against regressions in CI.

## Testing

- Golden fixtures expanded per feature (Map/Array/Xml as added); tricky-value
  corpus for `lib0`.
- Differential fuzzer: one random op stream → native / JS → identical state and
  (where required) identical bytes.
- CI runs the native suite directly with no foreign toolchain.

## Risk register

UTF-16 lengths · arena vs ARC · byte-exact `any`/number · YATA tie-break ·
out-of-order buffering · DeleteSet encoding. Each is covered by checked-in JS
vectors, convergence scenarios, and the recorded differential fuzz corpus.

## Effort (one strong engineer)

Task 1 (M1–M7) ≈ 6–9 weeks to §4 parity; Task 2 ≈ +2–3 months for the full type
set; M8 ongoing. The estimate is historical; the completed implementation now
uses the golden corpus for regression testing.
