import Foundation
import IOKit.ps

/// Fills the index in passes, so search improves within minutes (LOG 2026-10-30):
/// 1. words: all text into exact-word search, no model.
/// 2. notes: one vector per note and PDF, from its start.
/// 3. images: Apple's recognition, then one vector for that description.
/// 4. code: one vector per code or data file, from its start.
/// 5. deep: every piece of notes and PDFs, only on power.
/// Model work stops while the search box is open. Changed files jump the queue.
final class Indexer {
    enum Phase { case idle, words, notes, images, code, deep, done }

    private let index: MeaningIndex
    private let home: String
    private let server = EmbedServer(contextTokens: 2048)
    private let cond = NSCondition()
    private var urgent: [String] = []
    private var notes: [MeaningIndex.Pending] = []     // these three are popped from the end, newest last
    private var images: [MeaningIndex.Pending] = []
    private var code: [MeaningIndex.Pending] = []
    private var deepLeft = 0
    private var running = false
    private var holds = 0
    private var userPaused = false
    private var queued = false
    private var lastWork = Date()
    private var wordsDone = 0
    private var wordsTotal = 0
    private var phase = Phase.idle
    private var waitingForPower = false
    private var phaseStart = Date()
    var onProgress: (() -> Void)?
    var onPhaseDone: ((String, TimeInterval) -> Void)?

    /// Below this charge, on battery, model work waits. The deep pass always waits for power.
    static let minBattery = 50
    static let batch = 8

    init(index: MeaningIndex, home: String) { self.index = index; self.home = home }

    // MARK: Status

    /// Nothing is left that can run now. The deep pass may still be waiting for power.
    var isFinished: Bool {
        cond.lock(); defer { cond.unlock() }
        return queued && urgent.isEmpty && (phase == .done || (phase == .deep && waitingForPower))
    }
    var isPaused: Bool { cond.lock(); defer { cond.unlock() }; return userPaused }
    var isActive: Bool { cond.lock(); defer { cond.unlock() }; return phase != .done && phase != .idle }
    /// True until every file is searchable. The deep read after that runs quietly.
    var showsProgress: Bool { cond.lock(); defer { cond.unlock() }; return userPaused || (phase != .done && phase != .idle && phase != .deep) }

    func setPaused(_ p: Bool) { cond.lock(); userPaused = p; cond.broadcast(); cond.unlock() }

    /// The search box is open.
    func hold(_ on: Bool) { cond.lock(); holds = on ? 1 : 0; cond.broadcast(); cond.unlock() }

    /// What is ready and what is still coming, in words a person can use.
    var status: String {
        cond.lock(); defer { cond.unlock() }
        func n(_ v: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal) }
        if userPaused { return "Indexing paused" }
        switch phase {
        case .idle: return "Getting ready to read your files"
        case .words: return "Reading your files: \(n(wordsDone)) of \(n(wordsTotal))"
        case .notes: return waitingForPower ? "Exact words ready. Plug in to continue" : "Exact words ready. Notes and PDFs: \(n(notes.count)) left"
        case .images: return waitingForPower ? "Notes and PDFs ready. Plug in to continue" : "Notes and PDFs ready. Images: \(n(images.count)) left"
        case .code: return waitingForPower ? "Notes, PDFs and images ready. Plug in to continue" : "Notes, PDFs and images ready. Code: \(n(code.count)) left"
        case .deep: return waitingForPower ? "All files searchable. Plug in to read documents in full" : "All files searchable. Reading documents in full: \(n(deepLeft)) pieces left"
        case .done: return "Everything is up to date"
        }
    }

    // MARK: Starting

    /// Compares the list with the index, reads what is new or changed, then starts the model passes.
    func start(paths: [String]) {
        launch(paths: paths)
    }

    /// A file changed on disk. Runs next, even if the queue is long.
    func touch(_ path: String) {
        var st = stat()
        if lstat(path, &st) != 0 {
            DispatchQueue.global(qos: .utility).async { [self] in index.remove(path: path); onProgress?() }
            return
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, TextReader.kind(of: path) != nil else { return }
        cond.lock()
        urgent.removeAll { $0 == path }
        urgent.append(path)
        cond.broadcast()
        cond.unlock()
        launch(paths: nil)
    }

    private func launch(paths: [String]?) {
        cond.lock()
        let already = running
        running = true
        cond.unlock()
        if already {
            if let paths { DispatchQueue.global(qos: .utility).async { [self] in readWords(paths); refillQueues(); cond.lock(); cond.broadcast(); cond.unlock() } }
            return
        }
        let t = Thread { [self] in
            if let paths { readWords(paths) }
            refillQueues()
            loop()
        }
        t.qualityOfService = .utility
        t.start()
    }

    private func setPhase(_ p: Phase) {
        cond.lock()
        let old = phase, began = phaseStart
        if p != old { phase = p; phaseStart = Date() }
        cond.unlock()
        if p != old {
            if old != .idle { onPhaseDone?(Self.name(old), Date().timeIntervalSince(began)) }
            onProgress?()
        }
    }

    private static func name(_ p: Phase) -> String {
        switch p {
        case .idle: return "idle"; case .words: return "words"; case .notes: return "notes and PDFs"
        case .images: return "images"; case .code: return "code and data"; case .deep: return "deep read"; case .done: return "done"
        }
    }

    // MARK: Pass 1, words

    private func readWords(_ paths: [String]) {
        setPhase(.words)
        let known = index.known()
        let live = Set(paths)
        for (p, _) in known where !live.contains(p) { index.remove(path: p) }
        var todo: [(path: String, mtime: Int64, size: Int64, kind: TextReader.Kind)] = []
        for p in paths {
            guard let k = TextReader.kind(of: p) else { continue }
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let m = Int64(st.st_mtimespec.tv_sec), z = Int64(st.st_size)
            if let was = known[p], was.mtime == m, was.size == z { continue }
            todo.append((p, m, z, k))
        }
        todo.sort { rank($0.path, $0.mtime) < rank($1.path, $1.mtime) }
        cond.lock(); wordsTotal = todo.count; wordsDone = 0; cond.unlock()

        // PDFKit reads one file at a time for safety. Plain text and images use every core.
        var i = 0
        while i < todo.count {
            waitWhilePaused()
            let group = Array(todo[i..<min(i + 64, todo.count)])
            var rows = [MeaningIndex.Row?](repeating: nil, count: group.count)
            rows.withUnsafeMutableBufferPointer { out in
                let o = out.baseAddress!
                DispatchQueue.concurrentPerform(iterations: group.count) { n in
                    let g = group[n]
                    guard g.kind != .pdf else { return }
                    autoreleasepool { o[n] = Self.row(g.path, g.mtime, g.size, g.kind) }
                }
            }
            for (n, g) in group.enumerated() where g.kind == .pdf {
                autoreleasepool { rows[n] = Self.row(g.path, g.mtime, g.size, g.kind) }
            }
            index.putAll(rows.compactMap { $0 })
            i += group.count
            cond.lock(); wordsDone = i; cond.unlock()
            onProgress?()
        }
    }

    private static func row(_ p: String, _ m: Int64, _ z: Int64, _ k: TextReader.Kind) -> MeaningIndex.Row {
        var r = MeaningIndex.Row(path: p, mtime: m, size: z, kind: k)
        if k != .image { r.pieces = TextReader.read(p, kind: k).map { ($0.line, $0.text, nil) } }
        return r
    }

    /// Lower sorts first: your own folders, then newest.
    private func rank(_ path: String, _ mtime: Int64) -> (Int, Int64) {
        let own = ["/Desktop/", "/Documents/", "/Downloads/"].contains { path.hasPrefix(home + $0) }
        return (own ? 0 : 1, -mtime)
    }

    private func refillQueues() {
        let all = index.pending()
        func order(_ k: (TextReader.Kind) -> Bool) -> [MeaningIndex.Pending] {
            all.filter { k($0.kind) }.sorted { rank($0.path, $0.mtime) > rank($1.path, $1.mtime) }
        }
        let n = order { $0 == .note || $0 == .pdf }, im = order { $0 == .image }, c = order { $0 == .code }
        let deep = index.deepCount()
        cond.lock()
        notes = n; images = im; code = c; deepLeft = deep; queued = true
        cond.broadcast()
        cond.unlock()
    }

    // MARK: Passes 2 to 5

    private enum Job {
        case urgent(String)
        case files([MeaningIndex.Pending])
        case images([MeaningIndex.Pending])
        case deep
    }

    private func loop() {
        while true {
            let job = nextJob()
            lastWork = Date()
            autoreleasepool {
                switch job {
                case .urgent(let p): processUrgent(p)
                case .files(let f): embedHeads(f)
                case .images(let f): embedImages(f)
                case .deep: embedDeep()
                }
            }
            onProgress?()
        }
    }

    private func waitWhilePaused() {
        cond.lock()
        while userPaused { _ = cond.wait(until: Date().addingTimeInterval(5)) }
        cond.unlock()
    }

    /// Blocks until there is work the current power state allows.
    private func nextJob() -> Job {
        while true {
            let power = Self.powerState()
            cond.lock()
            if holds > 0 || userPaused { _ = cond.wait(until: Date().addingTimeInterval(5)); cond.unlock(); continue }
            if let p = urgent.popLast() { cond.unlock(); return .urgent(p) }
            let canModel = power.onAC || power.percent >= Self.minBattery
            let want: Phase = !notes.isEmpty ? .notes : !images.isEmpty ? .images : !code.isEmpty ? .code : deepLeft > 0 ? .deep : .done
            waitingForPower = want == .deep ? !power.onAC : (want != .done && !canModel)
            if want == .done || waitingForPower {
                cond.unlock()
                setPhase(want)
                cond.lock()
                if want == .done && Date().timeIntervalSince(lastWork) > 600 { server.stop() }
                _ = cond.wait(until: Date().addingTimeInterval(10))
                cond.unlock()
                continue
            }
            var job: Job
            switch want {
            case .notes: job = .files(Array(notes.suffix(Self.batch).reversed())); notes.removeLast(min(Self.batch, notes.count))
            case .images: job = .images(Array(images.suffix(Self.batch * 2).reversed())); images.removeLast(min(Self.batch * 2, images.count))
            case .code: job = .files(Array(code.suffix(Self.batch).reversed())); code.removeLast(min(Self.batch, code.count))
            default: job = .deep
            }
            cond.unlock()
            setPhase(want)
            return job
        }
    }

    private static func prompt(_ path: String, _ text: String) -> String {
        "title: \((path as NSString).lastPathComponent) | text: \(text)"
    }

    private func embedHeads(_ files: [MeaningIndex.Pending]) {
        let withText = files.filter { $0.pieceID != nil }
        guard server.start() else { requeueLater(); return }
        var vectors: [(pieceID: Int64, fileID: Int32, vector: [Float]?)] = []
        if !withText.isEmpty {
            let got = embedAll(withText.map { Self.prompt($0.path, $0.head) })
            for (f, v) in zip(withText, got) { vectors.append((f.pieceID!, f.fileID, v)) }
        }
        index.finish(vectors: vectors, files: files.map(\.fileID))
        refreshDeepCount()
    }

    private func embedImages(_ files: [MeaningIndex.Pending]) {
        guard server.start() else { requeueLater(); return }
        var seen = [(text: String, thumb: Data)?](repeating: nil, count: files.count)
        seen.withUnsafeMutableBufferPointer { out in
            let o = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                autoreleasepool { o[i] = TextReader.describe(files[i].path) }
            }
        }
        let known = files.indices.filter { seen[$0] != nil }
        let got = embedAll(known.map { Self.prompt(files[$0].path, seen[$0]!.text) })
        var byFile: [Int: [Float]?] = [:]
        for (i, v) in zip(known, got) { byFile[i] = v }
        for i in files.indices {
            let v = byFile[i] ?? nil
            index.finishImage(fileID: files[i].fileID, text: v == nil ? nil : seen[i]?.text, vector: v, thumb: seen[i]?.thumb)
        }
    }

    private func embedDeep() {
        guard server.start() else { requeueLater(); return }
        let pieces = index.pendingDeep(limit: Self.batch)
        guard !pieces.isEmpty else { cond.lock(); deepLeft = 0; cond.unlock(); return }
        let got = embedAll(pieces.map { Self.prompt($0.path, $0.text) })
        index.finish(vectors: zip(pieces, got).map { ($0.pieceID, $0.fileID, $1) }, files: [])
        cond.lock(); deepLeft = max(0, deepLeft - pieces.count); cond.unlock()
    }

    /// One piece the model refuses must not lose the rest of the batch.
    private func embedAll(_ prompts: [String]) -> [[Float]?] {
        guard !prompts.isEmpty else { return [] }
        if let vs = server.embed(texts: prompts), vs.count == prompts.count { return vs }
        return prompts.map { server.embed(texts: [$0])?.first }
    }

    private func requeueLater() {
        // The model server did not start: wait, then read the queues again from the index.
        usleep(30_000_000)
        refillQueues()
    }

    private func refreshDeepCount() {
        let c = index.deepCount()
        cond.lock(); deepLeft = c; cond.unlock()
    }

    private func processUrgent(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0, let kind = TextReader.kind(of: path) else { index.remove(path: path); return }
        index.putAll([Self.row(path, Int64(st.st_mtimespec.tv_sec), Int64(st.st_size), kind)])
        let p = index.pending(path: path)
        if kind == .image { embedImages(p) } else { embedHeads(p) }
    }

    // MARK: Power

    private static func powerState() -> (onAC: Bool, percent: Int) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (true, 100) }
        var percent = 100
        var onAC = list.isEmpty
        if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? { onAC = type == kIOPSACPowerValue }
        for src in list {
            if let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
               let c = d[kIOPSCurrentCapacityKey] as? Int { percent = c }
        }
        return (onAC, percent)
    }

    func stop() { server.stop() }
}
