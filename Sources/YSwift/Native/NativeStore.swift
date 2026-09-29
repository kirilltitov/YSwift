// The arena that owns every integrated struct: a `client -> [Struct]` map with the
// per-client arrays kept clock-ascending and gap-free. Ports yjs
// `utils/StructStore.js` (search / split / add) and the struct-splitting parts of
// `utils/DeleteSet.js` (`readAndApplyDeleteSet`).

final class NativeStore {
    /// Per-client structs, clock-ascending. The sole strong owner of every struct.
    var clients: [UInt64: [Struct]] = [:]
    /// Clients in the order their first struct arrived: the iteration order of the yjs
    /// `store.clients` Map, which `getStateVector` (and so an UndoManager's insertions) follows.
    private(set) var clientOrder: [UInt64] = []

    /// Bumped on every item split, so a transaction that only split items still merges them back
    /// on commit, as yjs does through `transaction._mergeStructs`.
    private(set) var splitCount = 0

    /// Splits `left` at `diff`, returning the new right half. The two halves are linked
    /// into the sibling list; the caller is responsible for inserting the right half
    /// into the store array (yjs `splitItem`, whose merge bookkeeping `splitCount` stands in for).
    private func splitItem(_ left: Item, _ diff: Int) -> Item {
        self.splitCount += 1
        let right = Item(
            id: YID(client: left.id.client, clock: left.id.clock + UInt64(diff)),
            origin: YID(client: left.id.client, clock: left.id.clock + UInt64(diff) - 1),
            rightOrigin: left.rightOrigin,
            parent: left.parent,
            parentID: nil,
            parentSub: left.parentSub,
            content: left.content.splice(diff)
        )
        if left.deleted { right.markDeleted() }
        // An UndoManager's protection and redo link cover both halves.
        if left.keep { right.setKeep(true) }
        if let redone = left.redone { right.redone = YID(client: redone.client, clock: redone.clock + UInt64(diff)) }
        right.left = left
        right.right = left.right
        (left.right as? Item)?.left = right
        left.right = right
        left.length = UInt64(diff)
        if let parentSub = right.parentSub, right.right == nil {
            right.parent?.map[parentSub] = right
        }
        return right
    }

    /// When non-nil, `deleteItem` logs `(client, clock, length)` for the deletes made
    /// during the current transaction (used to build the emitted update's delete set).
    var deleteLog: [(client: UInt64, clock: UInt64, length: UInt64)]?

    /// When non-nil, collects the names of root types changed during the current
    /// transaction (integrated/deleted items), for firing text observers on commit.
    var changedTypeNames: Set<String>?
    /// Immediate parent names used by observers do not prove top-level root coverage for nested
    /// types. Keep observer behavior intact and fail closed for that validation path.
    var changedRootNamesAreComplete = true

    /// When non-nil, the types changed during the current transaction, recorded under the rule of
    /// yjs `addChangedTypeToTransaction`: a nested type counts only if its item existed before the
    /// transaction (`transactionBeforeState`) and is not deleted.
    var changedTypes: [ObjectIdentifier: YTypeImpl]?
    var transactionBeforeState: [UInt64: UInt64] = [:]

    private func addChangedType(_ type: YTypeImpl?) {
        guard self.changedTypes != nil, let type else { return }
        if let item = type.item, item.deleted || item.id.clock >= self.transactionBeforeState[item.id.client] ?? 0 {
            return
        }
        self.changedTypes?[ObjectIdentifier(type)] = type
    }

    /// The root names in yjs `transaction.changedParentTypes`: every changed type whose item is not
    /// deleted by the end of the transaction reports itself and each type above it.
    func changedParentRootNames() -> Set<String> {
        var names = Set<String>()
        for type in (self.changedTypes ?? [:]).values where !(type.item?.deleted ?? false) {
            var current = type
            while let parent = current.item?.parent { current = parent }
            if current.item == nil, let name = current.name { names.insert(name) }
        }
        return names
    }

    private func checkChangedRootCompleteness(of item: Item) {
        guard let parent = item.parent, parent.item == nil, parent.name != nil else {
            self.changedRootNamesAreComplete = false
            return
        }
    }

    /// Marks `item` deleted, keeps parent length in sync, and records the deletion
    /// for the active transaction (`Item.delete`).
    func deleteItem(_ item: Item) {
        guard !item.deleted else { return }
        if item.countable, item.parentSub == nil {
            item.parent?.length -= Int(item.length)
        }
        item.markDeleted()
        self.version += 1
        self.deleteLog?.append((item.id.client, item.id.clock, item.length))
        if let name = item.parent?.name { self.changedTypeNames?.insert(name) }
        self.addChangedType(item.parent)
        self.checkChangedRootCompleteness(of: item)
        // `ContentType.delete`: a deleted type deletes its children, the list first, then the
        // current value of every key in the order the keys were first set.
        if case .type(let type, _, _) = item.content {
            var child = type.start
            while let current = child {
                self.deleteItem(current)
                child = current.right as? Item
            }
            for key in type.mapKeys {
                if let value = type.map[key] { self.deleteItem(value) }
            }
        }
    }

    /// Next expected clock for `client` (0 if unseen).
    func getState(_ client: UInt64) -> UInt64 {
        guard let structs = clients[client], let last = structs.last else { return 0 }
        return last.id.clock + last.length
    }

    /// `(client, clock)` pairs for the current state vector, sorted DESCENDING by
    /// client id — matching yjs `writeStateVector` (`sort((a, b) => b[0] - a[0])`)
    /// for byte-identical output.
    func stateVector() -> [(client: UInt64, clock: UInt64)] {
        self.clients.keys.sorted(by: >).map { (client: $0, clock: self.getState($0)) }
    }

    /// Monotonic count of structs integrated via `addStruct` — used to detect
    /// progress when retrying buffered (out-of-order) updates.
    private(set) var integratedCount = 0

    /// Bumped on every structural change (insert / delete) so cached search markers
    /// can tell when they are stale.
    private(set) var version = 0

    func addStruct(_ struct: Struct) {
        if clients[`struct`.id.client] == nil { self.clientOrder.append(`struct`.id.client) }
        clients[`struct`.id.client, default: []].append(`struct`)
        self.integratedCount += 1
        self.version += 1
        if let name = (`struct` as? Item)?.parent?.name { self.changedTypeNames?.insert(name) }
        if let item = `struct` as? Item {
            self.addChangedType(item.parent)
            self.checkChangedRootCompleteness(of: item)
        }
    }

    /// Binary search for the struct covering `clock` (ported from `findIndexSS`,
    /// including the pivot heuristic).
    func findIndex(_ structs: [Struct], _ clock: UInt64) -> Int {
        var left = 0
        var right = structs.count - 1
        var mid = structs[right]
        var midClock = mid.id.clock
        if midClock == clock { return right }
        var midIndex = Int((Double(clock) / Double(midClock + mid.length - 1)) * Double(right))
        while left <= right {
            mid = structs[midIndex]
            midClock = mid.id.clock
            if midClock <= clock {
                if clock < midClock + mid.length { return midIndex }
                left = midIndex + 1
            } else {
                right = midIndex - 1
            }
            midIndex = (left + right) / 2
        }
        preconditionFailure("findIndexSS: struct not found for clock \(clock)")
    }

    /// The struct at `id` (must exist).
    func getItem(_ id: YID) -> Struct {
        let structs = clients[id.client]!
        return structs[self.findIndex(structs, id.clock)]
    }

    /// Returns the struct ending at `id.clock`, splitting it there if `id` falls
    /// mid-struct (`getItemCleanEnd`). Returns the left half.
    func getItemCleanEnd(_ id: YID) -> Struct {
        var structs = clients[id.client]!
        let index = self.findIndex(structs, id.clock)
        let s = structs[index]
        if id.clock != s.id.clock + s.length - 1, let item = s as? Item {
            structs.insert(splitItem(item, Int(id.clock - item.id.clock + 1)), at: index + 1)
            clients[id.client] = structs
        }
        return s
    }

    /// Returns the struct starting at `id.clock`, splitting it there if `id` falls
    /// mid-struct (`getItemCleanStart`).
    func getItemCleanStart(_ id: YID) -> Struct {
        var structs = clients[id.client]!
        let index = self.findIndex(structs, id.clock)
        let s = structs[index]
        if s.id.clock < id.clock, let item = s as? Item {
            structs.insert(splitItem(item, Int(id.clock - item.id.clock)), at: index + 1)
            clients[id.client] = structs
            return structs[index + 1]
        }
        return s
    }

    /// Index of the struct starting at `clock` in `client`'s array, splitting the item covering it
    /// if needed (`findIndexCleanStart`).
    func findIndexCleanStart(_ client: UInt64, _ clock: UInt64) -> Int {
        var structs = clients[client]!
        let index = self.findIndex(structs, clock)
        if structs[index].id.clock < clock, let item = structs[index] as? Item {
            structs.insert(splitItem(item, Int(clock - item.id.clock)), at: index + 1)
            clients[client] = structs
            return index + 1
        }
        return index
    }

    /// Snapshot of `client -> next clock` for every known client.
    func snapshotState() -> [UInt64: UInt64] {
        var state: [UInt64: UInt64] = [:]
        for client in self.clients.keys { state[client] = self.getState(client) }
        return state
    }

    /// Transaction cleanup: replaces the content of the transaction's deleted items with
    /// `ContentDeleted` (GC with `parentGCd == false`) and merges adjacent compatible structs. Ports
    /// the `tryGcDeleteSet` + per-client `tryToMergeWithLefts` cleanup. Merging runs over every
    /// client, which is safe because already-merged runs are left untouched.
    func cleanup(gc: Bool, deletes: [(client: UInt64, clock: UInt64, length: UInt64)]) {
        var ranges: [UInt64: [(clock: UInt64, length: UInt64)]] = [:]
        if gc {
            for delete in deletes { ranges[delete.client, default: []].append((delete.clock, delete.length)) }
        }
        for client in self.clients.keys {
            if let ranges = ranges[client] { self.garbageCollect(client, ranges) }
            self.mergeClient(client)
        }
    }

    /// Collects the unprotected items the transaction deleted, and only those: an item deleted
    /// earlier under protection (`keep`) stays as it is once the protection is lifted, as in yjs.
    private func garbageCollect(_ client: UInt64, _ ranges: [(clock: UInt64, length: UInt64)]) {
        for range in ranges {
            // Collecting a type replaces its children with GC structs in place (the count never
            // changes), so structs are read afresh.
            let count = clients[client]!.count
            var index = self.findIndex(clients[client]!, range.clock)
            while index < count {
                let s = clients[client]![index]
                guard s.id.clock < range.clock + range.length else { break }
                index += 1
                guard let item = s as? Item, item.deleted, !item.keep else { continue }
                if case .deleted = item.content { continue }
                self.collect(item, parentGCd: false)
            }
        }
    }

    /// `Item.gc`: a deleted item keeps its clocks as `ContentDeleted`, or becomes a GC struct when
    /// the type holding it is collected. A collected type's children go first (`ContentType.gc`):
    /// once the type is gone they have no parent to be encoded with.
    private func collect(_ item: Item, parentGCd: Bool) {
        if case .type(let type, _, _) = item.content {
            var child = type.start
            while let current = child {
                child = current.right as? Item
                self.collect(current, parentGCd: true)
            }
            type.start = nil
            for latest in type.map.values {
                var entry: Item? = latest
                while let current = entry {
                    entry = current.left as? Item
                    self.collect(current, parentGCd: true)
                }
            }
            type.map = [:]
            type.mapKeys = []
        }
        if parentGCd {
            // `replaceStruct`
            let index = self.findIndex(clients[item.id.client]!, item.id.clock)
            clients[item.id.client]![index] = GCStruct(id: item.id, length: item.length)
        } else {
            item.content = .deleted(item.length)
        }
    }

    private func mergeClient(_ client: UInt64) {
        guard var structs = clients[client], structs.count > 1 else { return }
        var index = structs.count - 1
        while index >= 1 {
            index -= 1 + self.tryToMergeWithLefts(&structs, index)
        }
        clients[client] = structs
    }

    /// Merges `structs[pos]` leftward into contiguous compatible structs, removing
    /// absorbed entries. Returns how many were merged away (`tryToMergeWithLefts`).
    private func tryToMergeWithLefts(_ structs: inout [Struct], _ pos: Int) -> Int {
        var right = structs[pos]
        var left = structs[pos - 1]
        var index = pos
        while index > 0 {
            if left.isDeleted == right.isDeleted, type(of: left) == type(of: right), left.mergeWith(right) {
                // The merged item takes over as the key's current value.
                if let item = right as? Item, let key = item.parentSub, let parent = item.parent,
                    parent.map[key] === item, let merged = left as? Item
                {
                    parent.map[key] = merged
                }
                index -= 1
                right = left
                if index > 0 { left = structs[index - 1] }
                continue
            }
            break
        }
        let merged = pos - index
        if merged > 0 { structs.removeSubrange((pos + 1 - merged)...pos) }
        return merged
    }

    /// Applies a decoded delete set: splits at range boundaries and marks the
    /// covered items deleted (`readAndApplyDeleteSet`). Returns true if any delete
    /// referenced clocks not yet present (so the caller can buffer + retry).
    @discardableResult
    func applyDeleteSet(_ deleteSet: DeleteSetData) -> Bool {
        var dropped = false
        for client in deleteSet.clients {
            guard var structs = clients[client.client], !structs.isEmpty else {
                if !client.ranges.isEmpty { dropped = true }
                continue
            }
            let state = self.getState(client.client)
            for range in client.ranges {
                let clock = range.clock
                let clockEnd = clock + range.length
                guard clock < state else {
                    dropped = true
                    continue
                }
                if state < clockEnd { dropped = true }  // tail [state, clockEnd) not yet present
                var index = self.findIndex(structs, clock)
                if let item = structs[index] as? Item, !item.deleted, item.id.clock < clock {
                    structs.insert(splitItem(item, Int(clock - item.id.clock)), at: index + 1)
                    index += 1
                }
                while index < structs.count {
                    let s = structs[index]
                    index += 1
                    guard s.id.clock < clockEnd else { break }
                    if let item = s as? Item, !item.deleted {
                        if clockEnd < item.id.clock + item.length {
                            structs.insert(splitItem(item, Int(clockEnd - item.id.clock)), at: index)
                        }
                        self.deleteItem(item)
                    }
                }
            }
            clients[client.client] = structs
        }
        return dropped
    }
}
