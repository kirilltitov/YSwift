// The arena that owns every integrated struct: a `client -> [Struct]` map with the
// per-client arrays kept clock-ascending and gap-free. Ports yjs
// `utils/StructStore.js` (search / split / add) and the struct-splitting parts of
// `utils/DeleteSet.js` (`readAndApplyDeleteSet`).

final class NativeStore {
    /// Per-client structs, clock-ascending. The sole strong owner of every struct.
    var clients: [UInt64: [Struct]] = [:]
    /// Each client's position in the order its first struct arrived: the iteration order of the yjs
    /// `store.clients` Map, which `getStateVector` (and so an UndoManager's insertions) follows.
    private var clientRank: [UInt64: Int] = [:]

    /// Bumped on every item split, so a transaction that only split items still merges them back
    /// on commit, as yjs does through `transaction._mergeStructs`.
    private(set) var splitCount = 0

    /// Yjs `transaction._mergeStructs`: ids the cleanup merges around besides the delete set and the
    /// structs the transaction added — the right half of every split, and every child a deleted type
    /// had lost in an earlier transaction (`ContentType.delete`).
    var mergeStructs: [YID] = []

    /// Whether a nested type was ever added; without one nothing nests.
    private var holdsTypes = false

    deinit {
        // A type also owns the current value of each of its keys (`YTypeImpl.map`), so a chain of
        // nested map entries would be released recursively, one stack frame per level, and a deep
        // enough chain overflows the stack. With that ownership cut, the structs go one by one.
        guard self.holdsTypes else { return }
        for structs in self.clients.values {
            for case let item as Item in structs {
                if case .type(let type, _, _) = item.content { type.map = [:] }
            }
        }
    }

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
        self.mergeStructs.append(right.id)
        if let parentSub = right.parentSub, right.right == nil {
            right.parent?.map[parentSub] = right
        }
        return right
    }

    /// When non-nil, the ids deleted during the current transaction (yjs `transaction.deleteSet`).
    var deleteSet: DeleteSet?
    /// Whether `deleteItem` deleted an item, and a type, during the current transaction. Only these
    /// deletions leave content to collect (an item that arrives deleted holds none), and only a type's
    /// collection can fail (`collectionFails`).
    var deletedItemInTransaction = false
    var deletedTypeInTransaction = false

    /// When non-nil, collects the names of root types changed during the current
    /// transaction (integrated/deleted items), for firing text observers on commit.
    var changedTypeNames: Set<String>?
    /// Immediate parent names used by observers do not prove top-level root coverage for nested
    /// types. Keep observer behavior intact and fail closed for that validation path.
    var changedRootNamesAreComplete = true

    /// When non-nil, the types changed during the current transaction, recorded under the rule of
    /// yjs `addChangedTypeToTransaction`: a nested type counts only if its item existed before the
    /// transaction (`beforeState`) and is not deleted.
    var changedTypes: [ObjectIdentifier: YTypeImpl]?

    /// The clock of every client the current transaction added structs to, as it was before the
    /// transaction (yjs `transaction.beforeState` for the clients that changed). Recorded by
    /// `addStruct`; the transaction resets it.
    var transactionBeforeState: [UInt64: UInt64] = [:]

    /// `client`'s clock before the current transaction: a client it added nothing to is unchanged.
    func beforeState(_ client: UInt64) -> UInt64 {
        self.transactionBeforeState[client] ?? self.getState(client)
    }

    /// The clients the current transaction added structs to, with their clocks before and after,
    /// in the order of the yjs `store.clients` Map that `transaction.afterState` follows.
    func transactionChanges() -> [(client: UInt64, before: UInt64, after: UInt64)] {
        self.transactionBeforeState
            .map { (client: $0.key, before: $0.value, after: self.getState($0.key)) }
            .sorted { self.clientRank[$0.client]! < self.clientRank[$1.client]! }
    }

    private func addChangedType(_ type: YTypeImpl?) {
        guard self.changedTypes != nil, let type else { return }
        if let item = type.item, item.deleted || item.id.clock >= self.beforeState(item.id.client) {
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

    /// How many levels of nested content a remote update may build or delete. Yjs deletes and collects
    /// a type's children recursively and throws once the stack runs out: in browsers from 734 levels
    /// on (WebKit, in a worker). Past this depth a remote update is rejected (see DECISIONS.md), so that
    /// whatever the document accepts, browsers can delete.
    static let remoteNestingLimit = 512

    /// `remoteNestingLimit` for this store. Only tests lift it, to build deeper documents.
    var nestingLimit = NativeStore.remoteNestingLimit

    /// Whether a run resent from its middle after a struct of another parent or key is rejected. Only tests
    /// lift it, to build the chains yjs builds from such runs and check that every walk over them ends.
    var rejectsRunsUnderAnotherParent = true

    /// Set while a remote update is applied: a deletion reaching deeper than `nestingLimit`, or a type's
    /// list that leads back into itself (yjs deletes along it without end), then sets
    /// `remoteDeletionFailed`, for the update to be rejected.
    var limitsDeletionDepth = false
    var remoteDeletionFailed = false

    /// Marks `item` deleted, keeps parent length in sync, and records the deletion
    /// for the active transaction (`Item.delete`).
    func deleteItem(_ item: Item) {
        // `ContentType.delete`: a deleted type deletes its children, the list first, then the
        // current value of every key in the order the keys were first set. A work list keeps that
        // order without a stack frame per level of nesting.
        var pending: [(item: Item, depth: Int)] = [(item, 1)]
        while let (item, depth) = pending.popLast() {
            guard !item.deleted else {
                // `ContentType.delete`: a child deleted before this transaction is in no delete set of
                // it, yet it is collected with the type; queue it so the cleanup merges it.
                if depth > 1, item.id.clock < self.beforeState(item.id.client) {
                    self.mergeStructs.append(item.id)
                }
                continue
            }
            if self.limitsDeletionDepth, depth > self.nestingLimit { self.remoteDeletionFailed = true }
            if item.countable, item.parentSub == nil {
                item.parent?.length -= Int(item.length)
            }
            item.markDeleted()
            self.deletedItemInTransaction = true
            self.version += 1
            self.deleteSet?.add(item.id.client, item.id.clock, item.length)
            if let name = item.parent?.name { self.changedTypeNames?.insert(name) }
            self.addChangedType(item.parent)
            self.checkChangedRootCompleteness(of: item)
            if case .type(let type, _, _) = item.content {
                self.deletedTypeInTransaction = true
                var children: [Item] = []
                var listed = Set<ObjectIdentifier>()
                var child = type.start
                while let current = child {
                    guard listed.insert(ObjectIdentifier(current)).inserted else {
                        if self.limitsDeletionDepth { self.remoteDeletionFailed = true }
                        break
                    }
                    children.append(current)
                    child = current.right as? Item
                }
                for key in type.mapKeys {
                    if let value = type.map[key] { children.append(value) }
                }
                pending.append(contentsOf: children.reversed().lazy.map { ($0, depth + 1) })
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

    /// Bumped on every structural change (insert / delete) so cached search markers
    /// can tell when they are stale.
    private(set) var version = 0

    func addStruct(_ struct: Struct) {
        let client = `struct`.id.client
        if self.transactionBeforeState[client] == nil { self.transactionBeforeState[client] = self.getState(client) }
        if clients[client] == nil { self.clientRank[client] = self.clientRank.count }
        clients[client, default: []].append(`struct`)
        self.version += 1
        if let name = (`struct` as? Item)?.parent?.name { self.changedTypeNames?.insert(name) }
        if let item = `struct` as? Item {
            if case .type = item.content { self.holdsTypes = true }
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

    /// The index of the struct covering `clock` and the struct, with one lookup of the client's
    /// array, which is not held on return: a split then inserts into it without copying it.
    private func lookup(_ client: UInt64, _ clock: UInt64) -> (index: Int, struct: Struct) {
        let structs = self.clients[client]!
        let index = self.findIndex(structs, clock)
        return (index, structs[index])
    }

    /// Returns the struct ending at `id.clock`, splitting it there if `id` falls
    /// mid-struct (`getItemCleanEnd`). Returns the left half.
    func getItemCleanEnd(_ id: YID) -> Struct {
        let (index, s) = self.lookup(id.client, id.clock)
        if id.clock != s.id.clock + s.length - 1, let item = s as? Item {
            // Inserted in place: a copy of the client's array per split made many splits quadratic.
            let right = splitItem(item, Int(id.clock - item.id.clock + 1))
            clients[id.client]!.insert(right, at: index + 1)
        }
        return s
    }

    /// Returns the struct starting at `id.clock`, splitting it there if `id` falls
    /// mid-struct (`getItemCleanStart`).
    func getItemCleanStart(_ id: YID) -> Struct {
        let (index, s) = self.lookup(id.client, id.clock)
        guard let item = s as? Item, item.id.clock < id.clock else { return s }
        let right = splitItem(item, Int(id.clock - item.id.clock))
        clients[id.client]!.insert(right, at: index + 1)
        return right
    }

    /// Index of the struct starting at `clock` in `client`'s array, splitting the item covering it
    /// if needed (`findIndexCleanStart`).
    func findIndexCleanStart(_ client: UInt64, _ clock: UInt64) -> Int {
        let (index, s) = self.lookup(client, clock)
        if let item = s as? Item, item.id.clock < clock {
            let right = splitItem(item, Int(clock - item.id.clock))
            clients[client]!.insert(right, at: index + 1)
            return index + 1
        }
        return index
    }

    /// Yjs `cleanupTransactions`: collects the transaction's delete set, sorted and merged, in every
    /// client first (`tryGcDeleteSet`), then merges only what the transaction touched: around each delete
    /// range (`tryMergeDeleteSet`), the structs it added (`changes`), and around `mergeStructs`, in reverse.
    /// Merges within a client do not depend on other clients, so the client order does not change the result.
    func cleanup(gc: Bool, deleteSet: DeleteSet, changes: [(client: UInt64, before: UInt64, after: UInt64)]) {
        if gc, self.deletedItemInTransaction {
            for entry in deleteSet.clients { self.garbageCollect(entry.client, entry.ranges) }
        }
        for entry in deleteSet.clients {
            // A range within the structs the transaction added is merged with them below: merging
            // adjacent structs gives the same structs in any order.
            let before = self.beforeState(entry.client)
            let added = self.getState(entry.client) != before ? before : UInt64.max
            self.mergeAround(&self.clients[entry.client]!, entry.ranges.lazy.filter { $0.clock < added })
        }
        for change in changes where change.after != change.before {
            self.mergeFrom(&self.clients[change.client]!, change.before)
        }
        for id in self.mergeStructs.reversed() {
            let position = self.findIndex(self.clients[id.client]!, id.clock)
            if position + 1 < self.clients[id.client]!.count,
                self.tryToMergeWithLefts(&self.clients[id.client]!, position + 1) > 1
            {
                continue
            }
            if position > 0 { _ = self.tryToMergeWithLefts(&self.clients[id.client]!, position) }
        }
        self.mergeStructs = []
    }

    /// `tryMergeDeleteSet` for one client's ranges, in reverse.
    private func mergeAround<Ranges: BidirectionalCollection<(clock: UInt64, length: UInt64)>>(
        _ structs: inout [Struct],
        _ ranges: Ranges,
    ) {
        for range in ranges.reversed() {
            let last = self.findIndex(structs, range.clock + range.length - 1)
            var index = min(structs.count - 1, last + 1)
            while index > 0, structs[index].id.clock >= range.clock {
                index -= 1 + self.tryToMergeWithLefts(&structs, index)
            }
        }
    }

    /// Merges the structs from `clock` on, which the transaction added, with their left neighbours.
    private func mergeFrom(_ structs: inout [Struct], _ clock: UInt64) {
        let first = max(self.findIndex(structs, clock), 1)
        var index = structs.count - 1
        while index >= first {
            index -= 1 + self.tryToMergeWithLefts(&structs, index)
        }
    }

    /// Collects the unprotected items the transaction deleted, and only those: an item deleted
    /// earlier under protection (`keep`) stays as it is once the protection is lifted, as in yjs.
    private func garbageCollect(_ client: UInt64, _ ranges: [(clock: UInt64, length: UInt64)]) {
        // Collecting a type replaces its children with GC structs in place (the count never changes):
        // the local copy is dropped first, so that the store's array is not copied, and read afresh.
        var structs = clients[client]!
        for range in ranges {
            var index = self.findIndex(structs, range.clock)
            while index < structs.count {
                let s = structs[index]
                guard s.id.clock < range.clock + range.length else { break }
                index += 1
                guard let item = s as? Item, item.deleted, !item.keep else { continue }
                if case .deleted = item.content { continue }
                guard case .type = item.content else {
                    self.collect(item, parentGCd: false)
                    continue
                }
                structs = []
                self.collect(item, parentGCd: false)
                structs = clients[client]!
            }
        }
    }

    /// `Item.gc`: a deleted item keeps its clocks as `ContentDeleted`, or becomes a GC struct when
    /// the type holding it is collected. A collected type's children go first (`ContentType.gc`):
    /// once the type is gone they have no parent to be encoded with. A work list does so without a
    /// stack frame per level of nesting.
    ///
    /// Every item is collected once: a list or key chain that leads back into itself or into a type
    /// being collected, which `collectionFails` rejects in remote updates, would otherwise grow the
    /// work list without end.
    private func collect(_ item: Item, parentGCd: Bool) {
        var pending: [(item: Item, parentGCd: Bool, childrenCollected: Bool)] = [(item, parentGCd, false)]
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(item)]
        while let (item, parentGCd, childrenCollected) = pending.popLast() {
            if case .type(let type, _, _) = item.content {
                guard childrenCollected else {
                    pending.append((item, parentGCd, true))
                    var children: [Item] = []
                    var child = type.start
                    while let current = child, visited.insert(ObjectIdentifier(current)).inserted {
                        children.append(current)
                        child = current.right as? Item
                    }
                    for latest in type.map.values {
                        var entry: Item? = latest
                        while let current = entry, visited.insert(ObjectIdentifier(current)).inserted {
                            children.append(current)
                            entry = current.left as? Item
                        }
                    }
                    pending.append(contentsOf: children.reversed().lazy.map { ($0, true, false) })
                    continue
                }
                type.start = nil
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
    }

    /// Whether collecting the unprotected types among `deletes` fails in yjs, which collects a type's
    /// children recursively (`ContentType.gc`): a list or key chain that leads back into itself loops
    /// there without end, a type reached again while it is being collected recurses until the stack
    /// runs out, and a child that is not deleted throws (`Item.gc`). The last happens without a cycle:
    /// yjs deletes only a key's current value with the type, but collects the whole key chain. Walks
    /// the types as yjs does, without changing them and without recursion.
    ///
    /// The answer does not depend on the order the types are walked in: it is whether any type reachable
    /// from them has such a chain or child, or leads back into a type on the way to it, and a type is only
    /// skipped once a walk through it found neither.
    func collectionFails(_ deletes: DeleteSet) -> Bool {
        guard self.deletedTypeInTransaction else { return false }
        var collected = Set<ObjectIdentifier>()
        for entry in deletes.clients {
            guard let structs = self.clients[entry.client] else { continue }
            for delete in entry.ranges {
                var index = self.findIndex(structs, delete.clock)
                while index < structs.count, structs[index].id.clock < delete.clock + delete.length {
                    defer { index += 1 }
                    guard let item = structs[index] as? Item, item.deleted, !item.keep,
                        case .type(let type, _, _) = item.content
                    else { continue }
                    if self.collectionFails(type, &collected) { return true }
                }
            }
        }
        return false
    }

    /// `collectionFails` for one type and the types nested in it. `collected` holds the types already
    /// walked: yjs has emptied them.
    private func collectionFails(_ root: YTypeImpl, _ collected: inout Set<ObjectIdentifier>) -> Bool {
        guard !collected.contains(ObjectIdentifier(root)) else { return false }
        // The types being collected, outermost first, each with its children and the next one to visit.
        var walk: [(type: YTypeImpl, children: [Item], next: Int)] = []
        var walking = Set<ObjectIdentifier>()
        /// Starts collecting `type`; false if one of its chains leads back into itself.
        func enter(_ type: YTypeImpl) -> Bool {
            var children: [Item] = []
            var seen = Set<ObjectIdentifier>()
            var child = type.start
            while let current = child {
                guard seen.insert(ObjectIdentifier(current)).inserted else { return false }
                children.append(current)
                child = current.right as? Item
            }
            for key in type.mapKeys {
                seen.removeAll(keepingCapacity: true)
                var entry = type.map[key]
                while let current = entry {
                    guard seen.insert(ObjectIdentifier(current)).inserted else { return false }
                    children.append(current)
                    entry = current.left as? Item
                }
            }
            walk.append((type, children, 0))
            walking.insert(ObjectIdentifier(type))
            return true
        }
        guard enter(root) else { return true }
        while let top = walk.last {
            guard top.next < top.children.count else {
                walk.removeLast()
                walking.remove(ObjectIdentifier(top.type))
                collected.insert(ObjectIdentifier(top.type))
                continue
            }
            walk[walk.count - 1].next += 1
            let child = top.children[top.next]
            guard child.deleted else { return true }
            guard case .type(let nested, _, _) = child.content, !collected.contains(ObjectIdentifier(nested)) else {
                continue
            }
            guard !walking.contains(ObjectIdentifier(nested)), enter(nested) else { return true }
        }
        return false
    }

    /// Merges `structs[pos]` leftward into contiguous compatible structs, removing
    /// absorbed entries. Returns how many were merged away (`tryToMergeWithLefts`).
    ///
    /// Yjs merges from right to left, each struct absorbing the run to its right; appending the
    /// run to its first struct instead gives the same structs without copying the run once per
    /// struct in it.
    private func tryToMergeWithLefts(_ structs: inout [Struct], _ pos: Int) -> Int {
        var first = pos
        while first > 0 {
            let left = structs[first - 1]
            let right = structs[first]
            guard left.isDeleted == right.isDeleted, type(of: left) == type(of: right), left.canMerge(with: right)
            else { break }
            first -= 1
        }
        guard first < pos else { return 0 }
        let merged = structs[first]
        for index in (first + 1)...pos {
            let right = structs[index]
            _ = merged.mergeWith(right)
            // The merged item takes over as the key's current value.
            if let item = right as? Item, let key = item.parentSub, let parent = item.parent, parent.map[key] === item {
                parent.map[key] = merged as? Item
            }
        }
        structs.removeSubrange((first + 1)...pos)
        return pos - first
    }

    /// Applies a delete set: splits at range boundaries and marks the covered items deleted
    /// (`readAndApplyDeleteSet`). Returns the ranges of clocks not present yet, to be applied later.
    func applyDeleteSet(_ deleteSet: DeleteRanges) -> DeleteRanges {
        var unapplied: DeleteRanges = []
        // The store's arrays are changed in place, one short access at a time: a local copy of a client's
        // array was copied again by its first split, and `deleteItem` reads the store too.
        for client in deleteSet {
            let id = client.client
            var rest: [(clock: UInt64, length: UInt64)] = []
            defer { if !rest.isEmpty { unapplied.append((id, rest)) } }
            guard self.clients[id]?.isEmpty == false else {
                rest = client.ranges
                continue
            }
            let state = self.getState(id)
            for range in client.ranges {
                let clock = range.clock
                let clockEnd = clock + range.length
                guard clock < state else {
                    rest.append(range)
                    continue
                }
                if state < clockEnd { rest.append((state, clockEnd - state)) }
                var index = self.findIndex(self.clients[id]!, clock)
                if let item = self.clients[id]![index] as? Item, !item.deleted, item.id.clock < clock {
                    let right = self.splitItem(item, Int(clock - item.id.clock))
                    self.clients[id]!.insert(right, at: index + 1)
                    index += 1
                }
                while index < self.clients[id]!.count {
                    let s = self.clients[id]![index]
                    index += 1
                    guard s.id.clock < clockEnd else { break }
                    if let item = s as? Item, !item.deleted {
                        if clockEnd < item.id.clock + item.length {
                            let right = self.splitItem(item, Int(clockEnd - item.id.clock))
                            self.clients[id]!.insert(right, at: index)
                        }
                        self.deleteItem(item)
                    }
                }
            }
        }
        return unapplied
    }
}
