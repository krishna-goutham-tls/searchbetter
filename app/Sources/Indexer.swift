import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

/// Fills the index in passes, so search improves within minutes (LOG 2026-10-30):
/// 1. words: all text into exact-word search, no model.
/// 2. notes: one vector per note and PDF, from its start.
/// 3. images: Apple's recognition, then one vector for that description.
/// 4. code: one vector per code or data file, from its start.
/// 5. deep: every piece of notes and PDFs, only on power.
/// Model work stops while the search box is open. Changed files jump the queue.
///
/// Model work must never slow the apps in use (LOG 2026-11-18). So:
/// - it rests after each job, at least as long as the job took, and 3 times as long while the person uses the Mac;
/// - the deep read runs only after 2 minutes without keyboard or mouse use;
/// - it waits in Low Power Mode, when macOS reports the Mac as hot, and while another app keeps the GPU busy;
/// - each request to the model is small, so the GPU is free to draw the screen between requests;
/// - its llama-server runs at background priority.
final class Indexer {
    enum Phase { case idle, words, notes, images, code, deep, done }

    private let index: MeaningIndex
    private let home: String
    private let server = EmbedServer(contextTokens: 2048, background: true)
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
    private var busy = false                            // waiting for the Mac: hot, Low Power Mode or GPU in use
    private var deepBuffer: [MeaningIndex.DeepPiece] = []   // loop thread only
    private var lastDeepCount = Date.distantPast             // loop thread only
    private var countedAtEnd = false                         // guarded by cond
    var onProgress: (() -> Void)?
    var onPhaseDone: ((String, TimeInterval) -> Void)?

    /// Below this charge, on battery, model work waits. The deep pass always waits for power.
    static let minBattery = 50
    static let batch = 8
    /// The person counts as away after this long without keyboard or mouse use.
    /// `--away-after <seconds>` changes it, to test the in-use case while nobody types.
    static let awayAfter: TimeInterval = args.firstIndex(of: "--away-after").flatMap { i in
        i + 1 < args.count ? TimeInterval(args[i + 1]) : nil } ?? 120
    /// Rest after a job, as a multiple of the job's time: GPU share at most 1 / (1 + rest).
    static let restWhileAway = 1.0
    static let restWhileInUse = 3.0
    /// Another app keeps the GPU this busy: wait.
    static let gpuBusyPercent = 85
    /// One request to the model holds at most this many texts and characters, so one GPU pass stays short.
    static let requestTexts = 2
    static let requestChars = 2000
    /// `--full-speed` skips the rests and the gates, for tests and timing runs.
    static let fullSpeed = args.contains("--full-speed")

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

    /// A folder was skipped: drop its queued work and remove what the index holds for it.
    func forget(folder: String) {
        let inside: (String) -> Bool = { $0.hasPrefix(folder + "/") }
        cond.lock()
        urgent.removeAll(where: inside)
        notes.removeAll { inside($0.path) }
        images.removeAll { inside($0.path) }
        code.removeAll { inside($0.path) }
        cond.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            for p in index.known().keys where inside(p) { index.remove(path: p) }
            onProgress?()
        }
    }

    func setPaused(_ p: Bool) { cond.lock(); userPaused = p; cond.broadcast(); cond.unlock() }

    /// The search box is open.
    func hold(_ on: Bool) { cond.lock(); holds = on ? 1 : 0; cond.broadcast(); cond.unlock() }

    /// What is ready and what is still coming, in words a person can use.
    var status: String {
        cond.lock(); defer { cond.unlock() }
        func n(_ v: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal) }
        if userPaused { return "Indexing paused" }
        if busy && phase != .done && phase != .deep { return "Waiting while your Mac is busy" }
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
        if lstat(path, &st) != 0 || Skips.shared.skipsContent(path, home: home) {
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
        // Files in skipped folders leave the index here too, so a skip made while the app was closed takes effect.
        let readable = paths.filter { !Skips.shared.skipsContent($0, home: home) }
        let live = Set(readable)
        for (p, _) in known where !live.contains(p) { index.remove(path: p) }
        var todo: [(path: String, mtime: Int64, size: Int64, kind: TextReader.Kind)] = []
        for p in readable {
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
            let began = Date()
            lastWork = began
            autoreleasepool {
                switch job {
                case .urgent(let p): processUrgent(p)
                case .files(let f): embedHeads(f)
                case .images(let f): embedImages(f)
                case .deep: embedDeep()
                }
            }
            onProgress?()
            rest(after: Date().timeIntervalSince(began))
        }
    }

    /// Leaves the GPU and CPU free for a while, in proportion to the job just done.
    private func rest(after took: TimeInterval) {
        guard !Self.fullSpeed else { return }
        let factor = Self.idleSeconds() < Self.awayAfter ? Self.restWhileInUse : Self.restWhileAway
        let until = Date().addingTimeInterval(min(30, took * factor))
        cond.lock()
        while Date() < until { _ = cond.wait(until: until) }
        cond.unlock()
    }

    // MARK: The Mac's state

    /// Seconds since the last keyboard, mouse or trackpad event. Needs no permission.
    static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// The GPU's busy share, as Activity Monitor's GPU history reads it. Nil if macOS does not report it.
    static func gpuPercent() -> Int? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var top: Int?
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any], let u = stats["Device Utilization %"] as? Int {
                top = max(top ?? 0, u)
            }
        }
        return top
    }

    /// True when model work should wait: Low Power Mode, a hot Mac, or another app using the GPU.
    /// Read after a rest, so the GPU reading is mostly other apps.
    static func macIsBusy() -> Bool {
        if fullSpeed { return false }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        if info.thermalState == .serious || info.thermalState == .critical { return true }
        if let g = gpuPercent(), g >= gpuBusyPercent { return true }
        return false
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
            if want == .done && deepLeft == 0 && !countedAtEnd {
                // The deep count refreshes at most every 30 s. Count once more before calling it done.
                countedAtEnd = true
                cond.unlock()
                refreshDeepCount(force: true)
                continue
            }
            if want != .done { countedAtEnd = false }
            if want == .done || waitingForPower {
                cond.unlock()
                setPhase(want)
                cond.lock()
                // Any wait longer than 10 minutes frees the model's memory. It loads again in about a second.
                if Date().timeIntervalSince(lastWork) > 600 { server.stop() }
                _ = cond.wait(until: Date().addingTimeInterval(10))
                cond.unlock()
                continue
            }
            // Gates for bulk work. A changed file (urgent, above) is one small job and goes first.
            cond.unlock()
            let blocked = Self.macIsBusy()
            let inUse = !Self.fullSpeed && Self.idleSeconds() < Self.awayAfter
            cond.lock()
            busy = blocked
            if blocked || (want == .deep && inUse) {
                cond.unlock()
                setPhase(want)
                onProgress?()
                cond.lock()
                if Date().timeIntervalSince(lastWork) > 600 { server.stop() }
                _ = cond.wait(until: Date().addingTimeInterval(blocked ? 10 : 5))
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
        // One sorted query per 256 pieces, not per batch: the sort reads every waiting piece.
        // A piece whose file changed meanwhile is harmless: its id is gone, so the update writes nothing.
        if deepBuffer.isEmpty { deepBuffer = index.pendingDeep(limit: 256) }
        let pieces = Array(deepBuffer.prefix(Self.batch))
        deepBuffer.removeFirst(pieces.count)
        guard !pieces.isEmpty else { cond.lock(); deepLeft = 0; cond.unlock(); return }
        let got = embedAll(pieces.map { Self.prompt($0.path, $0.text) })
        index.finish(vectors: zip(pieces, got).map { ($0.pieceID, $0.fileID, $1) }, files: [])
        cond.lock(); deepLeft = max(0, deepLeft - pieces.count); cond.unlock()
    }

    /// One piece the model refuses must not lose the rest of the batch.
    /// Sends small requests (`requestTexts`, `requestChars`), so each GPU pass is short and the screen can draw in between.
    private func embedAll(_ prompts: [String]) -> [[Float]?] {
        var out: [[Float]?] = []
        out.reserveCapacity(prompts.count)
        var i = 0
        while i < prompts.count {
            var j = i + 1, chars = prompts[i].count
            while j < prompts.count, j - i < Self.requestTexts, chars + prompts[j].count <= Self.requestChars {
                chars += prompts[j].count; j += 1
            }
            let part = Array(prompts[i..<j])
            if let vs = server.embed(texts: part), vs.count == part.count { out += vs.map { Optional($0) } }
            else { out += part.map { server.embed(texts: [$0])?.first } }
            i = j
        }
        return out
    }

    private func requeueLater() {
        // The model server did not start: wait, then read the queues again from the index.
        usleep(30_000_000)
        refillQueues()
    }

    private func refreshDeepCount(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastDeepCount) > 30 else { return }
        lastDeepCount = Date()
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
        if args.contains("--ignore-power") { return (true, 100) }   // for tests on a laptop on battery
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
