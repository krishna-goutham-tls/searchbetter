// Test 2: name search per keystroke. Test 4: binary vector scan plus int8 re-check.
// Usage: scan <paths.txt>
import Foundation

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
func pct(_ xs: [Double], _ p: Double) -> Double { let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
func report(_ label: String, _ ms: [Double]) {
    print(String(format: "%@  median %.2f ms  p95 %.2f ms  max %.2f ms", label, pct(ms, 0.5), pct(ms, 0.95), ms.max()!))
}
let cores = ProcessInfo.processInfo.activeProcessorCount

// MARK: Test 2 - file names

struct NameIndex {
    var names: [[UInt8]] = []   // lowercased file name bytes
    init(_ paths: [String]) {
        names.reserveCapacity(paths.count)
        for p in paths { names.append(Array((p as NSString).lastPathComponent.lowercased().utf8)) }
    }
    // Score: name starts with query 3, a word in the name starts with it 2, substring 1.
    func search(_ q: [UInt8], top: Int = 20) -> [(Int, Int)] {
        let chunk = (names.count + cores - 1) / cores
        var partial = [[(Int, Int)]](repeating: [], count: cores)
        partial.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: cores) { c in
                var hits: [(Int, Int)] = []
                let lo = c * chunk, hi = min(names.count, lo + chunk)
                if lo >= hi { return }
                for i in lo..<hi {
                    let n = names[i]
                    if n.count < q.count { continue }
                    var best = 0
                    var j = 0
                    while j <= n.count - q.count {
                        if n[j] == q[0] {
                            var k = 1
                            while k < q.count && n[j + k] == q[k] { k += 1 }
                            if k == q.count {
                                let s = j == 0 ? 3 : (n[j - 1] == 32 || n[j - 1] == 45 || n[j - 1] == 95 || n[j - 1] == 46) ? 2 : 1
                                if s > best { best = s }
                                if best == 3 { break }
                            }
                        }
                        j += 1
                    }
                    if best > 0 { hits.append((best, i)) }
                }
                hits.sort { $0.0 != $1.0 ? $0.0 > $1.0 : names[$0.1].count < names[$1.1].count }
                buf[c] = Array(hits.prefix(top))
            }
        }
        return Array(partial.flatMap { $0 }.sorted { $0.0 > $1.0 }.prefix(top))
    }
}

func nameTest(_ paths: [String], label: String) {
    let t = now()
    let idx = NameIndex(paths)
    print(String(format: "\n[names] %@: %d names, index built in %.0f ms", label, paths.count, now() - t))
    let queries = ["invoice", "readme", "screenshot", "pricing", "agents", "whiteboard", "budget 2026", "lidawake"]
    var ms: [Double] = []
    for q in queries {                       // type each query one key at a time
        let b = Array(q.utf8)
        for n in 1...b.count {
            let t0 = now(); _ = idx.search(Array(b[0..<n])); ms.append(now() - t0)
        }
    }
    report("[names] per keystroke (\(ms.count) keystrokes)", ms)
}

// MARK: Test 4 - vectors

func vectorTest(pieces: Int) {
    let words = 12                                   // 768 bits = 12 x UInt64
    var rng = SystemRandomNumberGenerator()
    let bin = UnsafeMutablePointer<UInt64>.allocate(capacity: pieces * words)
    for i in 0..<(pieces * words) { bin[i] = rng.next() }
    // int8 vectors on disk, read back through mmap like the real app would.
    let file = NSTemporaryDirectory() + "macsearch-int8-\(pieces).bin"
    if !FileManager.default.fileExists(atPath: file) {
        var bytes = [UInt8](repeating: 0, count: pieces * 768)
        for i in 0..<(pieces * 96) { let r = rng.next() as UInt64; for b in 0..<8 { bytes[i * 8 + b] = UInt8(truncatingIfNeeded: r >> (b * 8)) } }
        let d = Data(bytes)
        try! d.write(to: URL(fileURLWithPath: file))
    }
    let int8 = try! Data(contentsOf: URL(fileURLWithPath: file), options: .alwaysMapped)
    let k = 400
    var scanMs: [Double] = [], rescoreMs: [Double] = []
    for _ in 0..<50 {
        var q = [UInt64](repeating: 0, count: words)
        for i in 0..<words { q[i] = rng.next() }
        let qf = (0..<768).map { _ in Float.random(in: -1...1) }
        let t0 = now()
        let chunk = (pieces + cores - 1) / cores
        var partial = [[(Int, Int)]](repeating: [], count: cores)
        partial.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: cores) { c in
                let lo = c * chunk, hi = min(pieces, lo + chunk)
                // Keep the k smallest distances with a counting threshold (distances are 0...768).
                var hist = [Int](repeating: 0, count: 769)
                var dist = [UInt16](repeating: 0, count: max(0, hi - lo))
                q.withUnsafeBufferPointer { qp in
                    for i in lo..<hi {
                        let v = bin + i * words
                        var d = 0
                        for w in 0..<words { d += (v[w] ^ qp[w]).nonzeroBitCount }
                        dist[i - lo] = UInt16(d); hist[d] += 1
                    }
                }
                var cut = 0, seen = 0
                while cut < 769 && seen < k { seen += hist[cut]; cut += 1 }
                var out: [(Int, Int)] = []
                for i in 0..<dist.count where Int(dist[i]) < cut { out.append((Int(dist[i]), lo + i)) }
                buf[c] = out
            }
        }
        let cands = partial.flatMap { $0 }.sorted { $0.0 < $1.0 }.prefix(k)
        let t1 = now()
        // Re-check in parallel: each core reads its share of candidates from the SSD.
        let cl = Array(cands)
        var scores = [Float](repeating: 0, count: cl.count)
        scores.withUnsafeMutableBufferPointer { sb in
            int8.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let p = raw.bindMemory(to: Int8.self)
                DispatchQueue.concurrentPerform(iterations: cl.count) { c in
                    var s: Float = 0
                    let base = cl[c].1 * 768
                    for j in 0..<768 { s += Float(p[base + j]) * qf[j] }
                    sb[c] = s
                }
            }
        }
        var scored = zip(scores, cl.map { $0.1 }).map { ($0, $1) }
        scored.sort { $0.0 > $1.0 }
        let t2 = now()
        scanMs.append(t1 - t0); rescoreMs.append(t2 - t1)
    }
    print(String(format: "\n[vectors] %d pieces, binary %.0f MB in RAM, int8 %.0f MB on disk", pieces,
                 Double(pieces * 96) / 1_048_576, Double(pieces * 768) / 1_048_576))
    report("[vectors] binary scan, top \(k)", scanMs)
    report("[vectors] int8 re-check of top \(k)", rescoreMs)
    bin.deallocate()
}

let pathsFile = CommandLine.arguments[1]
let real = try! String(contentsOfFile: pathsFile, encoding: .utf8).split(separator: "\n").map(String.init)
nameTest(real, label: "this Mac")
var big: [String] = []                       // a heavier Mac: the same names repeated to 1M
while big.count < 1_000_000 { for p in real { big.append(p + "\(big.count % 97)") } }
nameTest(Array(big.prefix(1_000_000)), label: "synthetic heavy Mac")

for n in [350_000, 1_000_000, 3_000_000] { vectorTest(pieces: n) }
