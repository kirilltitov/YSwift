// Id ranges per client, ported from yjs `utils/DeleteSet.js`. A transaction collects the ids it
// deletes in one (`transaction.deleteSet`), and an UndoManager stack item is a pair of them.

/// yjs `DeleteSet`: clients in the order they were first added (a JS `Map`), ranges
/// clock-ascending and merged once `sortAndMerge` has run.
struct DeleteSet {
    private(set) var clients: [(client: UInt64, ranges: [(clock: UInt64, length: UInt64)])] = []
    /// Index of each client in `clients`.
    private var indices: [UInt64: Int] = [:]

    var isEmpty: Bool { self.clients.isEmpty }

    /// `addToDeleteSet`.
    mutating func add(_ client: UInt64, _ clock: UInt64, _ length: UInt64) {
        if let index = self.indices[client] {
            self.clients[index].ranges.append((clock, length))
        } else {
            self.indices[client] = self.clients.count
            self.clients.append((client, [(clock, length)]))
        }
    }

    /// `sortAndMergeDeleteSet`.
    mutating func sortAndMerge() {
        for index in self.clients.indices {
            var merged: [(clock: UInt64, length: UInt64)] = []
            for range in self.clients[index].ranges.sorted(by: { $0.clock < $1.clock }) {
                if let last = merged.last, last.clock + last.length >= range.clock {
                    let length = max(last.length, range.clock + range.length - last.clock)
                    merged[merged.count - 1] = (last.clock, length)
                } else {
                    merged.append(range)
                }
            }
            self.clients[index].ranges = merged
        }
    }

    /// `mergeDeleteSets([self, other])`.
    func merged(with other: DeleteSet) -> DeleteSet {
        var result = self
        for entry in other.clients {
            for range in entry.ranges { result.add(entry.client, range.clock, range.length) }
        }
        result.sortAndMerge()
        return result
    }

    /// `isDeleted`: a binary search (`findIndexDS`), so the ranges must be sorted and merged.
    func contains(_ id: YID) -> Bool {
        guard let index = self.indices[id.client] else { return false }
        let ranges = self.clients[index].ranges
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = ranges[middle]
            if range.clock <= id.clock {
                if id.clock < range.clock + range.length { return true }
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return false
    }

    /// `writeDeleteSet`: clients written highest id first.
    func write(into encoder: inout Lib0Encoder) {
        encoder.writeVarUint(UInt64(self.clients.count))
        for entry in self.clients.sorted(by: { $0.client > $1.client }) {
            encoder.writeVarUint(entry.client)
            encoder.writeVarUint(UInt64(entry.ranges.count))
            for range in entry.ranges {
                encoder.writeVarUint(range.clock)
                encoder.writeVarUint(range.length)
            }
        }
    }
}
