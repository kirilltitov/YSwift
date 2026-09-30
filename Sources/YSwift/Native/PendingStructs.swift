// The structs and deletions a document keeps while they wait for clocks it lacks, as yjs keeps them in
// `store.pendingStructs` and `store.pendingDs` (utils/encoding.js `readUpdateV2`). Yjs keeps them as one
// encoded update and merges every new remainder into it with `mergeUpdatesV2` (utils/updates.js); the
// merge is ported here over the structs themselves, which have not been integrated and so have not
// changed since they were read.

/// Delete ranges per client.
typealias DeleteRanges = [(client: UInt64, ranges: [(clock: UInt64, length: UInt64)])]

/// Structs that wait for clocks the document lacks: per client, clock-ascending, as a merged yjs update
/// holds them, and per client the lowest clock that is missing (yjs `missing`).
struct PendingStructs {
    var missing: [UInt64: UInt64]
    var structs: [UInt64: [Struct]]

    /// `mergeUpdatesV2([self, other])` for the structs: clients from the highest, clocks ascending. Where
    /// both hold a clock, the struct met first wins and the other is sliced to start after it; a gap
    /// between the structs of a client becomes a skip.
    func merged(with other: PendingStructs) -> PendingStructs {
        var missing = self.missing
        for (client, clock) in other.missing where missing[client].map({ clock < $0 }) ?? true {
            missing[client] = clock
        }
        var readers = [Reader(self.structs), Reader(other.structs)]
        var written: [Struct] = []
        var current: Struct?

        while true {
            readers.removeAll { $0.current == nil }
            Self.sort(&readers)
            guard let reader = readers.first else { break }
            let firstClient = reader.current!.id.client
            if let write = current {
                var next = reader.current
                var iterated = false
                // Skip what has been written already.
                while let candidate = next, candidate.id.clock + candidate.length <= write.id.clock + write.length,
                    candidate.id.client >= write.id.client
                {
                    next = reader.advance()
                    iterated = true
                }
                guard let candidate = next, candidate.id.client == firstClient,
                    !iterated || candidate.id.clock <= write.id.clock + write.length
                else { continue }
                if firstClient != write.id.client {
                    written.append(write)
                    current = candidate
                    reader.advance()
                } else if write.id.clock + write.length < candidate.id.clock {
                    if write is SkipStruct {
                        write.length = candidate.id.clock + candidate.length - write.id.clock
                    } else {
                        written.append(write)
                        let end = write.id.clock + write.length
                        current = SkipStruct(id: YID(client: firstClient, clock: end), length: candidate.id.clock - end)
                    }
                } else {
                    var candidate = candidate
                    let diff = write.id.clock + write.length - candidate.id.clock
                    if diff > 0 {
                        if write is SkipStruct {
                            write.length -= diff
                        } else {
                            candidate = Self.slice(candidate, diff)
                        }
                    }
                    if !write.mergeWith(candidate) {
                        written.append(write)
                        current = candidate
                        reader.advance()
                    }
                }
            } else {
                current = reader.current
                reader.advance()
            }
            while let next = reader.current, let write = current, next.id.client == firstClient,
                next.id.clock == write.id.clock + write.length, !(next is SkipStruct)
            {
                written.append(write)
                current = next
                reader.advance()
            }
        }
        if let current { written.append(current) }

        // Read back as yjs reads the merged update: a client's structs come in one run, and a later run of
        // the same client would replace it.
        var structs: [UInt64: [Struct]] = [:]
        var index = 0
        while index < written.count {
            let client = written[index].id.client
            var end = index
            while end < written.count, written[end].id.client == client { end += 1 }
            structs[client] = Array(written[index..<end])
            index = end
        }
        return PendingStructs(missing: missing, structs: structs)
    }

    /// Orders the readers as yjs does: higher clients first, then lower clocks. For two structs at one clock
    /// of different kinds the yjs comparator says the first argument goes first whichever it is, so the
    /// result is the one V8's sort gives, a binary insertion sort that asks whether each reader goes before
    /// the ones already sorted: a later reader goes first.
    private static func sort(_ readers: inout [Reader]) {
        func compare(_ lhs: Struct, _ rhs: Struct) -> Int {
            guard lhs.id.client == rhs.id.client else { return rhs.id.client > lhs.id.client ? 1 : -1 }
            guard lhs.id.clock == rhs.id.clock else { return lhs.id.clock < rhs.id.clock ? -1 : 1 }
            return type(of: lhs) == type(of: rhs) ? 0 : lhs is SkipStruct ? 1 : -1
        }
        for index in readers.indices.dropFirst() {
            let pivot = readers[index]
            var left = 0
            var right = index
            while left < right {
                let middle = left + (right - left) / 2
                if compare(pivot.current!, readers[middle].current!) < 0 {
                    right = middle
                } else {
                    left = middle + 1
                }
            }
            readers.remove(at: index)
            readers.insert(pivot, at: left)
        }
    }

    /// Yjs `sliceStruct`: the part of `struct` from `diff` on. A sliced item is written with its origin at
    /// the clock before it, and an item with an origin carries no parent on the wire: when it is read back
    /// it takes its parent and key from its neighbours, as yjs reads it.
    private static func slice(_ struct: Struct, _ diff: UInt64) -> Struct {
        let id = YID(client: `struct`.id.client, clock: `struct`.id.clock + diff)
        guard let item = `struct` as? Item else {
            return `struct` is SkipStruct
                ? SkipStruct(id: id, length: `struct`.length - diff)
                : GCStruct(id: id, length: `struct`.length - diff)
        }
        var content = item.content
        return Item(
            id: id,
            origin: YID(client: id.client, clock: id.clock - 1),
            rightOrigin: item.rightOrigin,
            parent: nil,
            parentID: nil,
            parentSub: nil,
            content: content.splice(Int(diff)),
        )
    }

    /// Reads the structs of a merged yjs update in order, leaving out skips (`LazyStructReader`).
    private final class Reader {
        private let structs: [Struct]
        private var index = -1
        private(set) var current: Struct?

        init(_ structs: [UInt64: [Struct]]) {
            self.structs = structs.keys.sorted(by: >).flatMap { structs[$0]! }
            self.advance()
        }

        @discardableResult
        func advance() -> Struct? {
            repeat { self.index += 1 } while self.index < self.structs.count && self.structs[self.index] is SkipStruct
            self.current = self.index < self.structs.count ? self.structs[self.index] : nil
            return self.current
        }
    }
}

/// `mergeDeleteSets` of two remainders of deletions: each client's ranges sorted and merged, clients from
/// the highest as yjs writes them.
func mergeDeleteRanges(_ lhs: DeleteRanges, _ rhs: DeleteRanges) -> DeleteRanges {
    var byClient: [UInt64: [(clock: UInt64, length: UInt64)]] = [:]
    for entry in lhs + rhs { byClient[entry.client, default: []] += entry.ranges }
    return byClient.keys.sorted(by: >).map { client in
        var merged: [(clock: UInt64, length: UInt64)] = []
        for range in byClient[client]!.sorted(by: { $0.clock < $1.clock }) {
            if let last = merged.last, last.clock + last.length >= range.clock {
                merged[merged.count - 1].length = max(last.length, range.clock + range.length - last.clock)
            } else {
                merged.append(range)
            }
        }
        return (client, merged)
    }
}
