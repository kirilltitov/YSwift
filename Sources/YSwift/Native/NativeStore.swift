// The arena that owns every integrated struct: a `client -> [Struct]` map with the
// per-client arrays kept clock-ascending and gap-free. Ports yjs
// `utils/StructStore.js` (search / split / add) and the struct-splitting parts of
// `utils/DeleteSet.js` (`readAndApplyDeleteSet`).

/// Splits `left` at `diff`, returning the new right half. The two halves are linked
/// into the sibling list; the caller is responsible for inserting the right half
/// into the store array (mirrors yjs `splitItem`, minus merge/undo bookkeeping).
private func splitItem(_ left: Item, _ diff: Int) -> Item {
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

final class NativeStore {
    /// Per-client structs, clock-ascending. The sole strong owner of every struct.
    var clients: [UInt64: [Struct]] = [:]

    /// When non-nil, `deleteItem` logs `(client, clock, length)` for the deletes made
    /// during the current transaction (used to build the emitted update's delete set).
    var deleteLog: [(client: UInt64, clock: UInt64, length: UInt64)]?

    /// Marks `item` deleted, keeps parent length in sync, and records the deletion
    /// for the active transaction (`Item.delete`).
    func deleteItem(_ item: Item) {
        guard !item.deleted else { return }
        if item.countable, item.parentSub == nil {
            item.parent?.length -= Int(item.length)
        }
        item.markDeleted()
        self.deleteLog?.append((item.id.client, item.id.clock, item.length))
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

    func addStruct(_ struct: Struct) {
        clients[`struct`.id.client, default: []].append(`struct`)
        self.integratedCount += 1
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

    /// Snapshot of `client -> next clock` for every known client.
    func snapshotState() -> [UInt64: UInt64] {
        var state: [UInt64: UInt64] = [:]
        for client in self.clients.keys { state[client] = self.getState(client) }
        return state
    }

    /// Transaction cleanup: replaces deleted content with `ContentDeleted` (GC with
    /// `parentGCd == false`) and merges adjacent compatible structs. Ports the
    /// `tryGcDeleteSet` + per-client `tryToMergeWithLefts` cleanup. Runs over every
    /// client, which is safe because already-merged runs are left untouched.
    func cleanup(gc: Bool = true) {
        for client in self.clients.keys {
            if gc { self.garbageCollect(client) }
            self.mergeClient(client)
        }
    }

    private func garbageCollect(_ client: UInt64) {
        guard let structs = clients[client] else { return }
        for s in structs {
            guard let item = s as? Item, item.deleted else { continue }
            if case .deleted = item.content { continue }
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
