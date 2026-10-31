import Foundation

/// One line in the result list.
struct ResultRow {
    let path: String
    let isImage: Bool
    let pieceID: Int64?       // the piece that matched, for the matching line
    let query: String
    let score: Double
    let debug: String
}

/// Runs a search across the three layers and merges them into one list.
final class Engine {
    let files: FileIndex
    let dataDir: String
    private(set) var meaning: MeaningIndex?
    private(set) var indexer: Indexer?
    private let encoder = QueryEncoder()
    private var generation = 0

    /// A search for this long or shorter uses file names only.
    static let namesOnlyChars = 2
    /// The list waits this long for all layers, so it appears once and does not jump.
    static let settleMs = 40

    init(root: String?) {
        files = FileIndex(root: root)
        let base = NSHomeDirectory() + "/Library/Application Support/mac-search"
        dataDir = root.map { base + "/roots/" + Self.hash($0) } ?? base + "/home"
    }

    private static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    var meaningEnabled: Bool { meaning != nil }

    /// Opens the index and loads the vectors into RAM. Call off the main thread for a large index.
    func openMeaning() -> Bool {
        guard ModelFiles.available, let m = MeaningIndex(dir: dataDir) else { return false }
        let idx = Indexer(index: m, home: files.home)
        DispatchQueue.main.sync { meaning = m; indexer = idx }
        encoder.warmUp()
        return true
    }

    func shutdown() { encoder.stop(); indexer?.stop() }

    // MARK: Search

    /// Main thread. `update` runs on the main thread, once in the normal case. `final` is true on the last call.
    func search(_ query: String, update: @escaping ([ResultRow], Bool) -> Void) {
        generation += 1
        let gen = generation
        let names = files.search(query)
        let nameRows = names.map { ($0, files.paths[$0.id]) }
        guard let meaning, query.count > Self.namesOnlyChars else {
            update(merge(query, names: nameRows, exact: [], text: [], images: []), true)
            return
        }

        var exact: [MeaningIndex.Exact]?
        var vec: (text: [MeaningIndex.Hit], images: [MeaningIndex.Hit])?
        var drawn = false
        var previousTop: ResultRow?
        func publish(final: Bool) {
            guard gen == generation else { return }
            var rows = merge(query, names: nameRows, exact: exact ?? [], text: vec?.text ?? [], images: vec?.images ?? [])
            // A late layer may only replace the top row with a much stronger match.
            if let top = previousTop, let i = rows.firstIndex(where: { $0.path == top.path }), i > 0,
               rows[0].score < top.score * 1.5 {
                let r = rows.remove(at: i); rows.insert(r, at: 0)
            }
            previousTop = rows.first
            drawn = true
            update(rows, final)
        }
        func settle() { if exact != nil && vec != nil { publish(final: true) } }

        meaning.exact(query) { r in DispatchQueue.main.async { exact = r; settle() } }
        encoder.encode(query) { v in
            guard gen == self.generation else { return }
            guard let v else { vec = ([], []); settle(); return }
            DispatchQueue.global(qos: .userInteractive).async {
                let r = meaning.search(v)
                DispatchQueue.main.async { vec = r; settle() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.settleMs)) {
            if !drawn { publish(final: false) }
        }
    }

    /// All layers land on one scale, close to the model's own score. Values come from test searches on the
    /// demo folder (LOG 2026-10-30). Weak meaning hits are dropped, so a good match stands alone.
    private func merge(_ query: String, names: [(FileIndex.Hit, String)], exact: [MeaningIndex.Exact],
                       text: [MeaningIndex.Hit], images: [MeaningIndex.Hit]) -> [ResultRow] {
        struct Acc { var score = 0.0; var piece: Int64?; var why: [String] = [] }
        var acc: [String: Acc] = [:]
        let words = max(1, query.split(separator: " ").count)
        for (i, n) in names.enumerated() {
            let strong = n.0.score / words >= Self.strongNameScore
            acc[n.1, default: Acc()].score = (strong ? 0.78 : 0.58) - Double(i) * 0.002
            acc[n.1]!.why.append("name#\(i + 1)")
        }
        guard let meaning else { return rows(acc.map { ($0.key, $0.value.score, $0.value.piece, $0.value.why) }, query) }
        func take(_ hits: [MeaningIndex.Hit], floor: Float, offset: Double, tag: String) {
            guard let best = hits.first?.score else { return }
            for (i, h) in hits.enumerated() where h.score >= max(floor, best - Self.keepWithin) {
                guard let p = meaning.path(of: h.fileID) else { continue }
                var a = acc[p] ?? Acc()
                a.score = max(a.score, Double(h.score) + offset)
                if a.piece == nil { a.piece = h.pieceID }
                a.why.append(String(format: "%@#%d %.3f", tag, i + 1, h.score))
                acc[p] = a
            }
        }
        take(text, floor: Self.textFloor, offset: 0, tag: "text")
        take(images, floor: Self.imageFloor, offset: Self.imageOffset, tag: "image")
        // A strong match of one type hides weak matches of the other. Name matches do not count here.
        let meaningOnly = acc.filter { $0.value.why.allSatisfy { !$0.hasPrefix("name") } }
        if let best = meaningOnly.values.map(\.score).max() {
            for (p, a) in meaningOnly where a.score < best - Self.crossGap { acc[p] = nil }
        }
        for (i, e) in exact.enumerated() {
            guard let p = meaning.path(of: e.fileID) else { continue }
            var a = acc[p] ?? Acc()
            a.score = a.score > 0 ? a.score + Self.bothBonus : Self.exactScore - Double(i) * 0.002
            a.piece = e.pieceID   // show the line that holds the typed word
            a.why.append("word#\(i + 1)")
            acc[p] = a
        }
        return rows(acc.map { ($0.key, $0.value.score, $0.value.piece, $0.value.why) }, query)
    }

    static let strongNameScore = 200     // the word starts the name, or starts a word inside it
    static let textFloor: Float = 0.60
    static let imageFloor: Float = 0.58
    static let imageOffset = 0.04        // image scores sit lower than text scores for the same quality
    static let keepWithin: Float = 0.04
    static let crossGap = 0.05
    static let exactScore = 0.60
    static let bothBonus = 0.05
    static let maxRows = 12

    private func rows(_ items: [(String, Double, Int64?, [String])], _ query: String) -> [ResultRow] {
        items.sorted { $0.1 > $1.1 }.prefix(Self.maxRows).map {
            ResultRow(path: $0.0, isImage: TextReader.kind(of: $0.0) == .image, pieceID: $0.2, query: query, score: $0.1,
                      debug: $0.3.joined(separator: " "))
        }
    }

    // MARK: Row details

    /// The line to show under a file name: where a typed word appears, or the start of the matching piece.
    func snippet(for row: ResultRow) -> String? {
        guard !row.isImage, let id = row.pieceID, let meaning else { return nil }
        guard let p = meaning.piece(id) else { return nil }
        let lines = p.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let toks = row.query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
        var at = lines.firstIndex { l in toks.contains { l.lowercased().contains($0) } }
        if at == nil { at = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).count > 10 } }
        let i = at ?? 0
        let text = lines[i].trimmingCharacters(in: .whitespaces)
        let kind = TextReader.kind(of: row.path)
        let label = kind == .pdf ? "page \(p.line)" : "line \(p.line + i)"
        return "\(label):  \(text.prefix(160))"
    }

    func thumbnail(path: String) -> Data? { meaning?.thumb(path: path) }
}
