# Phase 2 — native Swift engine

Phase 1 shipped a working, conformance-verified library backed by Rust `yrs`
(`YrsEngine`). Phase 2 replaces the backend with a **pure-Swift `NativeEngine`**
behind the **same frozen public API**, then extends it to the rest of Yjs.

## Strategy — the payoff of the hybrid path

`NativeEngine` conforms to the internal `YEngine` protocol, exactly like
`YrsEngine`. Crucially, **`YrsEngine` stays in the tree as a differential
oracle**: both engines run in the same process, so beyond the golden vectors
from JS-Yjs we get instant cross-checks `NativeEngine ↔ YrsEngine` on arbitrary
inputs. Acceptance for every step: the existing conformance suite passes against
`NativeEngine` **byte-for-byte**, and property-based fuzzing (native / yrs / JS)
converges.

Locked design decisions (from the feasibility analysis):

- **Arena / handle store**, not an ARC pointer graph. `StructStore` owns
  per-client arrays; `left`/`right`/`parent`/`origin` are IDs/indices resolved
  through the store. No retain cycles, cache-friendly, `Sendable`-clean.
- **Text as `[UInt16]`** (UTF-16 code units) — matches Yjs clock/length
  semantics; reproduce `ContentString`'s surrogate-split → U+FFFD guard.
- **`YValue` with ordered object pairs** for byte-exact `lib0` `any`.
- **`lib0` v1 codec, byte-exact.** V2 (RLE) is deferred to Task 2.
- **Target: yjs v13.6.31** (our golden fixtures / `Cargo.lock` yrs 0.27.2).
- Native can **fix the multi-attribute `format` byte order** to match yjs
  (yrs uses HashMap order) — the current `semantic` fixture becomes byte-exact.

`ycs` (C#) is a near-line-by-line v13 port with a bundled `lib0`; used as a
structural **reference map**, not copied.

## Task 1 — native core + the current §4 API

| Milestone | Content | Gate (oracle) |
|---|---|---|
| **M1. lib0 v1 codec** | `Encoder`/`Decoder` over bytes; `varUint`/`varInt` (to 2^53, sign/continuation, `-0`), `varString` (UTF-8), fixed uint8/16/32, **big-endian** float32/64, `writeAny`/`readAny` (tags 116–127, int→float32→float64 dispatch). | Golden byte-vectors generated from `lib0` (Node) round-trip byte-identically. |
| **M2. Structs + store** | `ID`, `AbstractStruct`, `GC`, `Skip`, `Item`, arena `StructStore` (`findIndexSS`, clean-split); content types (`ContentString` on `[UInt16]`, `ContentAny`/`JSON`/`Deleted`/`Format`/`Type`/`Binary`/`Embed`/`Doc`). | Decode a golden update → structs → re-encode byte-identically (no integration). |
| **M3. YATA integrate + apply** | `Item.integrate` (two-set resolver, clientID tie-break), `readUpdate`/`writeClientsStructs`, `DeleteSet` + apply, minimal `Transaction`. | `applyUpdate(golden)` → correct text + state vector; `golden-decode` green. |
| **M4. Round-trip + out-of-order** | `encodeStateAsUpdate` (full + since-SV), pending/retry buffer for out-of-order updates. | `golden-encode` (byte) + `convergence` green; native/yrs/JS converge under shuffled delivery. |
| **M5. YText + toDelta** | local `insert`/`delete`/`format` (`ItemTextListPosition`, format markers), `toString`, `toDelta` state machine, search-marker cache. | `golden-encode` + `toDelta` green; multi-attribute format now byte-exact. |
| **M6. §4 surface** | `onUpdate` + transaction `origin`; `YUpdate.merge`/`diff`; `StickyIndex`; `Awareness`; `UndoManager`; `text.observe` (`YEvent`). | **All conformance tests** pass against `NativeEngine`. |
| **M7. Swap-in + fuzzing** | Engine selection in `makeDefaultEngine`; CI runs the suite against both engines; property-based differential tests (native vs yrs vs golden). | Full parity; `NativeEngine` becomes default, `YrsEngine` an optional oracle. |

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
   concurrent merge. Compare `NativeEngine` vs `YrsEngine` (and optionally JS).
2. **Profile-guided optimization rounds** (Instruments on macOS, `perf` on
   Linux): target the search-marker cache, arena access, `[UInt16]` splicing,
   allocation churn in encode/decode (`reserveCapacity`, `Span`/`RawSpan`,
   `~Copyable`/`InlineArray` where it pays). Goal: within a small factor of
   `yrs`; comfortably beat JS-Yjs.
3. Track results in this doc; guard against regressions in CI.

## Testing

- Golden fixtures expanded per feature (Map/Array/Xml as added); tricky-value
  corpus for `lib0`.
- Differential fuzzer: one random op stream → native / yrs / JS → identical
  state and (where required) identical bytes.
- CI runs the suite against both engines.

## Risk register (oracle catches divergence immediately)

UTF-16 lengths · arena vs ARC · byte-exact `any`/number · YATA tie-break ·
out-of-order buffering · DeleteSet encoding. Each is de-risked by having a live
`yrs` oracle rather than only offline JS vectors.

## Effort (one strong engineer)

Task 1 (M1–M7) ≈ 6–9 weeks to §4 parity; Task 2 ≈ +2–3 months for the full type
set; M8 ongoing. Dominated by byte-exact debugging — now against a local oracle.
