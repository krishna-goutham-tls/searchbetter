import Foundation

/// Where the model and the llama.cpp server live.
/// The server ships inside the app. The setup screen downloads the model.
enum ModelFiles {
    static let model = "embeddinggemma-2-Q8_0.gguf"

    static var helpers: String { Bundle.main.bundlePath + "/Contents/Helpers" }

    static var server: String? {
        let p = helpers + "/llama-server"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// The folder the setup screen downloads into.
    static var ownDir: String { NSHomeDirectory() + "/Library/Application Support/mac-search/models" }

    /// The app's own folder first. A Hugging Face cache copy saves a download on a developer Mac.
    static var dir: String? {
        let hub = NSHomeDirectory() + "/.cache/huggingface/hub/models--ggml-org--embeddinggemma-2-GGUF/snapshots"
        let snaps = (try? FileManager.default.contentsOfDirectory(atPath: hub)) ?? []
        return ([ownDir] + snaps.map { hub + "/" + $0 }).first { FileManager.default.fileExists(atPath: $0 + "/" + model) }
    }

    static var available: Bool { server != nil && dir != nil }

    /// A browser marks a download as quarantined, and the mark spreads to every file in the app.
    /// Approving the app covers the app, so clear the mark on the helper files it runs.
    static func clearHelperQuarantine() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: helpers)) ?? []
        for n in names { removexattr(helpers + "/" + n, "com.apple.quarantine", 0) }
    }
}

/// One llama-server child process on a free local port.
/// A small shell wrapper stops the server when this app dies, even after a crash.
final class EmbedServer {
    private let contextTokens: Int
    private var proc: Process?
    private var port: Int32 = 0
    private let lock = NSLock()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 180
        return URLSession(configuration: c)
    }()

    init(contextTokens: Int) { self.contextTokens = contextTokens }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return proc?.isRunning == true }

    /// Blocks until the model is loaded. Returns false if it cannot start.
    @discardableResult func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if proc?.isRunning == true { return true }
        guard let server = ModelFiles.server, let dir = ModelFiles.dir else { return false }
        port = Self.freePort()
        let args = ["-m", dir + "/" + ModelFiles.model, "--embedding", "--pooling", "mean", "-ngl", "99",
                    "--host", "127.0.0.1", "--port", String(port), "-np", "1", "--no-webui",
                    "-c", String(contextTokens), "-b", String(contextTokens), "-ub", String(contextTokens)]
        // kill -9: on a normal stop, llama-server aborts in its Metal cleanup and macOS logs a crash report.
        let script = #""$0" "$@" & c=$!; trap 'kill -9 $c 2>/dev/null' EXIT TERM; while kill -0 $PPID 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 2; done"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, server] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        proc = p
        for _ in 0..<600 {
            if !p.isRunning { return false }
            if let d = send("health", nil, timeout: 2), String(decoding: d, as: UTF8.self).contains("ok") {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        proc?.terminate()
        proc = nil
    }

    private static func freePort() -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        a.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        return Int32(UInt16(bigEndian: a.sin_port))
    }

    private func send(_ path: String, _ body: Data?, timeout: TimeInterval = 180) -> Data? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!, timeoutInterval: timeout)
        if let body { req.httpMethod = "POST"; req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        session.dataTask(with: req) { d, r, _ in
            if (r as? HTTPURLResponse)?.statusCode == 200 { out = d }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    private func vectors(_ data: Data?) -> [[Float]]? {
        guard let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let sorted = arr.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        var out: [[Float]] = []
        out.reserveCapacity(sorted.count)
        for item in sorted {
            guard let e = item["embedding"] as? [[NSNumber]], let v = e.first else { return nil }
            out.append(v.map { $0.floatValue })
        }
        return out
    }

    func embed(texts: [String]) -> [[Float]]? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["content": texts]) else { return nil }
        return vectors(send("embedding", body))
    }
}

/// Turns a typed search into a vector. Keeps only the newest search if keys arrive faster than the model.
final class QueryEncoder {
    private let server = EmbedServer(contextTokens: 512)
    private let queue = DispatchQueue(label: "mac-search.query", qos: .userInteractive)
    private var cache: [String: [Float]] = [:]   // main thread only
    private var running = false                  // main thread only
    private var waiting: (String, ([Float]?) -> Void)?

    func warmUp() { queue.async { [server] in server.start() } }
    func stop() { server.stop() }

    /// Main thread in, main thread out.
    func encode(_ query: String, done: @escaping ([Float]?) -> Void) {
        if let v = cache[query] { done(v); return }
        if running { waiting?.1(nil); waiting = (query, done); return }
        running = true
        queue.async { [self] in
            server.start()
            let v = server.embed(texts: ["task: search result | query: " + query])?.first
            DispatchQueue.main.async { [self] in
                running = false
                if let v {
                    if cache.count > 500 { cache.removeAll() }
                    cache[query] = v
                }
                done(v)
                if let w = waiting { waiting = nil; encode(w.0, done: w.1) }
            }
        }
    }
}
