import Foundation

/// Fills the meaning index in the background, newest files first. Stops while the search box is open,
/// so typing never competes with indexing for the GPU. Changed files jump the queue.
final class Indexer {
    private let index: MeaningIndex
    private let server = EmbedServer(images: true)
    private let cond = NSCondition()
    private var jobs: [String] = []         // popped from the end, so the newest is last
    private var pending = Set<String>()
    private var running = false
    private var holds = 0
    private var userPaused = false
    private var lastWork = Date()
    private var working = false
    private var queued = false
    private(set) var done = 0
    private(set) var total = 0
    var onProgress: (() -> Void)?

    init(index: MeaningIndex) { self.index = index }

    var remaining: Int { cond.lock(); defer { cond.unlock() }; return jobs.count }

    /// The list has been compared with the index and nothing is left to do.
    var isFinished: Bool { cond.lock(); defer { cond.unlock() }; return queued && jobs.isEmpty && !working }

    var isPaused: Bool { cond.lock(); defer { cond.unlock() }; return userPaused }

    func setPaused(_ p: Bool) { cond.lock(); userPaused = p; cond.broadcast(); cond.unlock() }

    /// The search box is open.
    func hold(_ on: Bool) { cond.lock(); holds = on ? 1 : 0; cond.broadcast(); cond.unlock() }

    /// Compares the list with the index, then queues what is new or changed and forgets what is gone.
    func start(paths: [String]) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let known = index.known()
            var todo: [(path: String, mtime: Int64)] = []
            let live = Set(paths)
            for (p, _) in known where !live.contains(p) { index.remove(path: p) }
            for p in paths where TextReader.kind(of: p) != nil {
                var st = stat()
                guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                if let k = known[p], k.mtime == Int64(st.st_mtimespec.tv_sec), k.size == Int64(st.st_size) { continue }
                todo.append((p, Int64(st.st_mtimespec.tv_sec)))
            }
            todo.sort { $0.mtime < $1.mtime }
            cond.lock()
            jobs = todo.map(\.path) + jobs
            pending.formUnion(todo.map(\.path))
            total = done + jobs.count
            queued = true
            cond.broadcast()
            cond.unlock()
            launch()
            onProgress?()
        }
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
        if let i = jobs.lastIndex(of: path), pending.contains(path) { jobs.remove(at: i); total -= 1 }
        jobs.append(path)
        pending.insert(path)
        total += 1
        cond.broadcast()
        cond.unlock()
        launch()
    }

    private func launch() {
        cond.lock(); defer { cond.unlock() }
        if running { return }
        running = true
        let t = Thread { [self] in loop() }
        t.qualityOfService = .utility
        t.start()
    }

    private func loop() {
        while true {
            cond.lock()
            while holds > 0 || userPaused || jobs.isEmpty {
                if jobs.isEmpty && holds == 0 && Date().timeIntervalSince(lastWork) > 600 {
                    server.stop()   // nothing to do for 10 minutes: give the memory back
                }
                _ = cond.wait(until: Date().addingTimeInterval(30))
            }
            let path = jobs.removeLast()
            pending.remove(path)
            working = true
            cond.unlock()

            autoreleasepool { process(path) }

            cond.lock()
            done += 1
            working = false
            lastWork = Date()
            cond.unlock()
            onProgress?()
        }
    }

    private func process(_ path: String) {
        guard let kind = TextReader.kind(of: path) else { return }
        var st = stat()
        guard lstat(path, &st) == 0 else { index.remove(path: path); return }
        let mtime = Int64(st.st_mtimespec.tv_sec), size = Int64(st.st_size)
        guard server.start() else { return }

        if kind == .image {
            guard let img = TextReader.prepareImage(path), let v = server.embed(jpeg: img.forModel) else {
                index.put(path: path, mtime: mtime, size: size, kind: kind, pieces: [], thumb: nil)
                return
            }
            index.put(path: path, mtime: mtime, size: size, kind: kind, pieces: [(0, "", v)], thumb: img.thumb)
            return
        }

        let parts = TextReader.read(path, kind: kind)
        let name = (path as NSString).lastPathComponent
        var rows: [(line: Int, text: String, vector: [Float])] = []
        var i = 0
        while i < parts.count {
            let batch = Array(parts[i..<min(i + 16, parts.count)])
            let prompts = batch.map { "title: \(name) | text: \($0.text)" }
            if let vs = server.embed(texts: prompts), vs.count == batch.count {
                for (p, v) in zip(batch, vs) { rows.append((p.line, p.text, v)) }
            } else {   // one piece the model refused must not lose the rest of the batch
                for (p, prompt) in zip(batch, prompts) {
                    if let v = server.embed(texts: [prompt])?.first { rows.append((p.line, p.text, v)) }
                }
            }
            i += 16
        }
        index.put(path: path, mtime: mtime, size: size, kind: kind, pieces: rows, thumb: nil)
    }

    func stop() { server.stop() }
}
