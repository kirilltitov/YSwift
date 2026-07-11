import YSwift

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Micro-benchmarks over the public YSwift API. The engine is chosen by
// makeDefaultEngine (YSWIFT_ENGINE=yrs for the Rust oracle, native otherwise), so
// run this twice and diff the two outputs.

let engineName = ProcessInfo.processInfo.environment["YSWIFT_ENGINE"] ?? "native"

func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
}

/// Formats a millisecond value to 3 decimals without Foundation's `String(format:)`
/// (unavailable in FoundationEssentials on Linux).
func format3(_ value: Double) -> String {
    let thousandths = Int((value * 1000).rounded())
    let whole = thousandths / 1000
    let fraction = String(thousandths % 1000)
    let padded = String(repeating: "0", count: 3 - fraction.count) + fraction
    return "\(whole).\(padded)"
}

/// Runs `body` `iterations` times after a warm-up and reports the best time.
func measure(_ label: String, iterations: Int = 5, _ body: () -> Void) {
    body()  // warm-up
    var best = Duration.seconds(1_000_000)
    for _ in 0..<iterations {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        if elapsed < best { best = elapsed }
    }
    let padded = label.count >= 34 ? label : label + String(repeating: " ", count: 34 - label.count)
    print("  \(padded) \(format3(milliseconds(best))) ms")
}

/// Builds a text of `count` single-char items by prepending (O(1) position lookup
/// per op → n distinct items, cheaply).
func buildManyItemDoc(_ count: Int) -> YDoc {
    let doc = YDoc(clientID: 1)
    let text = doc.text("content")
    doc.transact { txn in
        for _ in 0..<count { text.insert(txn, at: 0, "x") }
    }
    return doc
}

print("=== YSwift benchmarks [engine: \(engineName)] ===")

// W1: append-typing — insert one char at the END, N times (one transaction).
for n in [1000, 4000] {
    measure("type append x\(n)", iterations: 3) {
        let doc = YDoc(clientID: 1)
        let text = doc.text("content")
        doc.transact { txn in
            for i in 0..<n { text.insert(txn, at: i, "a") }
        }
    }
}

// W2: prepend-typing — insert one char at index 0, N times.
for n in [1000, 4000] {
    measure("type prepend x\(n)", iterations: 3) {
        let doc = YDoc(clientID: 1)
        let text = doc.text("content")
        doc.transact { txn in
            for _ in 0..<n { text.insert(txn, at: 0, "a") }
        }
    }
}

// Shared large doc for read/encode/apply benchmarks.
let bigDoc = buildManyItemDoc(5000)
let bigUpdate = bigDoc.transact { txn in bigDoc.encodeStateAsUpdate(txn) }
let bigSV = bigDoc.transact { txn in bigDoc.encodeStateVector(txn) }
print("  (big doc: 5000 items, update \(bigUpdate.count) bytes)")

// W3: encodeStateAsUpdate on the large doc.
measure("encodeStateAsUpdate 5000") {
    _ = bigDoc.transact { txn in bigDoc.encodeStateAsUpdate(txn) }
}

// W4: encodeStateVector.
measure("encodeStateVector 5000", iterations: 20) {
    _ = bigDoc.transact { txn in bigDoc.encodeStateVector(txn) }
}

// W5: applyUpdate of the large update into a fresh doc.
measure("applyUpdate 5000") {
    let doc = YDoc(clientID: 2)
    doc.transact { txn in doc.applyUpdate(txn, bigUpdate) }
}

// W6: applyUpdate since a state vector (diff) — nothing missing (worst-case scan).
measure("encodeStateAsUpdate(sinceSV) 5000") {
    _ = bigDoc.transact { txn in bigDoc.encodeStateAsUpdate(txn, since: bigSV) }
}

// W7: read the text.
measure("text.string 5000", iterations: 50) {
    _ = bigDoc.transact { txn in bigDoc.text("content").string(txn) }
}

print("=== done [\(engineName)] ===")
