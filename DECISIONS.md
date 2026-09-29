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
- **`UndoManager` tracks only the origins it is given.** Yjs's default `trackedOrigins` is
  `{null}` and it also matches an origin's constructor; a `Set<Origin>` can express neither, so
  a transaction without an origin is never captured. What a captured step undoes or redoes —
  which items are deleted or re-created, where, and in which order — is ported from Yjs 13.6.31
  and checked byte for byte against it (`UndoFuzzTests`).
- **`UndoManager` scope: one text or an array of texts of one document**, the `typeScope` forms
  of a Yjs `UndoManager` that a text-first API needs. A transaction is captured when it changes
  any text of the scope, and one `undo`/`redo` restores all of them in one transaction, as Yjs
  does. A change spanning several texts must be inverted by one manager over all of them: one
  manager per text sees only its own part and writes it in a separate transaction, so neither
  the bytes nor the number of updates match what a Yjs peer with the combined scope produces.
  A document as the scope, non-text types in the scope and `addToScope` are not provided: no
  consumer needs them, and a caller that knows the texts before the change passes them all.
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

## Transaction cleanup (GC and merge)

- **A document with `gc` collects the deleted items of the transaction's delete
  set** that no `UndoManager` protects (`keep`), as yjs `tryGcDeleteSet` does; a
  collected embedded type turns its children into GC structs. An item deleted
  under protection stays uncollected if the protection is lifted later.
- **The cleanup merges what the transaction touched, in yjs order.** All
  clients are collected first, then structs are merged around each delete
  range, over the structs the transaction added, and around the structs yjs
  records in `_mergeStructs` (the right half of every split and each child a
  deleted type had lost earlier), as `cleanupTransactions` does. Merging
  within a client does not depend on the others, so the encoded state no longer
  depends on the hash order of clients, which differed from process to
  process. Pinned by the `cleanup_*` undo fuzz scenarios.
- **A fresh tracked edit lifts the redo stack's protection**, as yjs
  `clear(false, true)` does when it drops a non-empty redo stack: its deleted
  items in scope and their parent items lose `keep` before the edit's own
  deletions are kept. An embedded type that only the redo stack protected is
  then collected by a later delete, children included. Pinned by the
  `audit_redo_*` undo fuzz scenarios.

## Remote update integration

- **A reference the document cannot resolve is rejected where yjs throws.**
  Yjs waits for references to other clients but resolves an item's references
  to its own client unchecked, and throws when one points at a clock that
  client has not reached. `applyUpdateChecked` reports `invalidUpdate` there
  instead of stopping the process. As in yjs `addStackToRestSS`, the structs of
  a client that follow an item waiting for a dependency wait with it and are not
  looked at until it arrives. Pinned by the `malformed` golden vectors.
- **A document whose client id an update uses takes a new one.** As in yjs,
  a transaction that applied an update and advanced the document's own client
  gives the document a new random 32-bit id when it commits, so that its later
  edits do not reuse clocks another peer wrote under that id; the update is
  still accepted. A mixed transaction (local edits and an update) counts, as in
  yjs. `YDoc.clientID` is therefore not stable; awareness keeps the id it was
  created with, as y-protocols does.
- **What yjs fails to collect is rejected.** A run sent again is linked in after
  the struct just before its first new clock whatever that struct's parent, in
  yjs, so a malformed update can thread one list or key chain into another
  until it leads back into itself (YSwift now rejects such a run, below, and
  keeps these checks as a second line). Yjs collects a deleted type's
  children recursively when the transaction ends, and there loops without end
  or overflows its stack. It also throws on a child that is not deleted, which
  needs no cycle: a type's deletion deletes only the current value of each key,
  yet its collection walks the whole key chain, where the left half of a split
  value may live on. With `gc`, `applyUpdateChecked` rejects an update after
  which collecting the transaction's deletions would fail; without
  `gc` nothing is collected and the update is accepted, as in yjs. The check
  runs before commit, so it does not see the protection an `UndoManager`
  tracking the update gives its deletions only then: with such a manager
  YSwift rejects an update yjs accepts and never collects. The check also runs
  after each update, while yjs collects once per transaction: of several
  updates applied in one transaction, YSwift rejects the first after which
  collection would fail, even where a later one deletes the live item and yjs
  accepts the whole transaction. Every update must be acceptable on its own,
  so that it is rejected before later ones build on it; only malformed input
  (a live item under a deleted type, or a chain that leads back into itself)
  gets there. Pinned by the
  `collected_map_keeps_live_split_half_until_the_same_transaction` vector. Every walk over
  such chains (collect, delete, `UndoManager` redo) stops at the first item it
  reaches twice. Undo and redo have no error to report: an item whose chains
  lead back into themselves is not redone, where yjs loops without end. Pinned
  by the `entry_resent_after_its_map_*` and `collected_*` malformed golden
  vectors and `CheckedUpdateTests+Cycles`.
- **A run resent from its middle after a GC struct is rejected.** Yjs links it
  in after the struct just before its first new clock and throws reading that
  struct's right neighbour, which a GC struct lacks, before changing anything;
  YSwift used to insert the run at the start of its parent. Pinned by the
  `resent_run_after_*` malformed golden vectors.
- **A run resent from its middle under another parent or key is rejected.** In
  a valid update the struct just before the run's first new clock is the part
  of the same run already held, with the same parent and key. Yjs links the
  run in after whatever struct is there, yet counts it in its own parent, so
  the lists stop matching the parents: a type whose parent is the root lies in
  the list of another type, and each such update nests one level deeper,
  unseen by a depth counted along the parents (a text's length can also drop
  below zero). Yjs applies this at any depth, fails to delete or render it past
  its stack, and its own encoding reloads into another document, in which the
  run takes the parent of its new left neighbour. YSwift rejects such a run,
  which yjs accepts; this is deliberate, and it keeps every item in its
  parent's list, so the nesting limit below holds for where items lie and a
  document reloads from its own encoding. Pinned by the
  `resent_run_under_another_*`, `entry_resent_after_its_map_kept`,
  `resent_run_after_collected_child_without_gc` and
  `collected_list_reaches_foreign_item_without_gc` malformed golden vectors
  (all accepted by yjs, marked `yswiftRejects`).
- **A remote update may build and delete 512 levels of nested content.** Yjs
  deletes and collects a type's children recursively and fails once the stack
  runs out (a `RangeError`, or in WebKit an `Unexpected case` from collecting
  the half-deleted chain), leaving the document damaged. Yjs 13.6.31 in
  Playwright's browsers (Chromium 149.0.7827.55, WebKit 26.5) fails at these
  depths, D nested types with the outermost deleted:

  | | Chromium main | Chromium worker | WebKit main | WebKit worker |
  |---|---|---|---|---|
  | maps, remote delete, gc | 1854–2042 | 912 | 7312–8254 | 734 |
  | maps, local delete, gc | 1914–2127 | 912 | 7382–8313 | 735 |
  | lists, remote delete, gc | 4188–8407 | 1733–1809 | 8870–15408 | 1557 |
  | lists, local delete, gc | 4125–8410 | 1798–1856 | 8750–15263 | 1559 |
  | applying the chain | no failure up to 256 000 | same | same | same |

  (ranges span cold and warm pages, minified and plain bundles and repeats;
  without gc the numbers are about the same; Node 26 fails at about 2200 maps
  and 3750 lists). Whatever YSwift accepts, browsers must be able to apply,
  collect and delete, so `applyUpdateChecked` rejects an update that nests
  an item deeper than `NativeStore.remoteNestingLimit` = 512 levels (about 30 %
  below the smallest failing depth, 734 in a WebKit worker, whose stack stands
  for the smaller stacks of mobile browsers) or deletes deeper than that. Yjs
  itself applies any depth, so YSwift rejects updates of 513 to about 2000
  levels that yjs accepts; this is deliberate. As in yjs, a rejected update has
  been applied in part, and the document must be discarded, as after any
  error. YSwift deletes, collects, re-creates (UndoManager) and releases nested
  types without recursion, so local edits and undo/redo, which have no error to
  report, work at any depth. Pinned by the `nested_*` malformed golden vectors
  (512 levels accepted and deleted, 513 rejected) and
  `CheckedUpdateTests+Depth`.

- **A sticky index is created for any index.** `StickyIndex.fromIndex` takes an
  index before the start as the start and one past the end as the end, as yjs
  does past the end. For a negative index yjs encodes an id before the first
  item, which no document resolves; YSwift does not copy that. A malformed
  update can drive a text's length below zero in yjs (a run resent from its
  middle joins the run before it, even one of another text); YSwift rejects
  such a run (`resent_run_under_another_root`).
- **Numbers keep their sign; every NaN is written as the quiet NaN.** lib0
  writes -0 as a zero varint with the sign bit, which YSwift now reads back as
  -0. Which NaN yjs writes back depends on the engine's `DataView`: WebKit
  always writes `7ff8000000000000`, V8 that for a signalling NaN but otherwise
  mostly the bits it read (a float32 NaN widened), not always the same way.
  YSwift writes `7ff8000000000000` for every NaN, which matches WebKit and,
  except for NaNs with a payload or a sign, V8. lib0 also reads a zero varint
  with a needless continuation byte (`7dc000`); YSwift rejects it, stricter
  than the browsers on purpose. Pinned by `AnyNumberTests` and the `any_*`
  malformed golden vectors.
- **Deep nesting is rendered, not refused.** Yjs renders XML elements
  recursively and throws from about 1172 nested levels; `YXmlFragment.toString`
  has no error to report and renders any depth.
- **An awareness update with a clock of 2^53 or more is ignored.** lib0 fails to
  read most such clocks and JS numbers do not hold them exactly; y-protocols
  then throws, `Awareness.applyUpdate` has no error to report and drops the
  update instead of stopping the process.

## Known limitations

- **Structs and deletions waiting for dependencies are kept as yjs keeps
  them**: only the part of an update that cannot integrate waits, merged with
  what already waits as `mergeUpdatesV2` merges it (slicing a run the other
  part holds, whose rest then takes its parent from its new origin), and it is
  retried once, as one update, when a clock it misses arrives; a retry that
  throws drops it, and the update that set it off reports the error. Waiting
  deletions are tried again with every update. `encodeStateAsUpdate` leaves
  what waits out; yjs includes it, so while something waits the encoded states
  differ. Yjs's V2 encoding of waiting deletions whose ranges overlap out of
  order writes negative deltas and corrupts them; YSwift keeps them intact.

- **Multi-attribute `format` byte order.** The public `Attributes` (and XML
  attribute) dictionaries are unordered, so a multi-attribute text `format` or
  XML element is serialised in sorted-key order. The result is deterministic
  and convergent, byte-exact when the peer used the same order, and otherwise a
  semantic match. Single-attribute formats are byte-identical. This is
  characterised by the `semantic` fixture.
- **Formatting cleanup after a remote transaction is not ported.** When a
  transaction that is not local changes a text holding formatting, yjs runs
  `cleanupYTextAfterTransaction` once the transaction ends: in a follow-up
  transaction of its own it deletes the format items the change left
  redundant, which emits an extra update and changes the encoded state. YSwift
  keeps those items (they repeat formatting already in effect, so the text and
  its delta are the same) and emits no such update; a peer's cleanup update is
  applied as any other. Local deletions do clean up formatting
  (`cleanupFormattingGap`). Recorded scenarios that reach this are left out of
  the undo corpus (`TEXT_CLEANUP_GAP` in `fixtures/undo-fuzz.mjs`); random
  valid scenarios with formatting and remote edits reach it often.
- `UndoManager` and `Awareness` are **not `Sendable`** (single-context helpers);
  wrap in an actor if shared across connections.
- `YSwift.UndoManager` shadows `Foundation.UndoManager` — qualify when both are
  imported.

## Still open

- Whether native Apple clients (iOS/macOS) also consume the port (requirements
  §11) — affects how much Apple-platform API ergonomics matter.
