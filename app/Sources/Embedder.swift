import Foundation

/// Where the model and the llama.cpp server live on this Mac.
enum ModelFiles {
    static let server = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static let dir: String? = {
        let hub = NSHomeDirectory() + "/.cache/huggingface/hub/models--ggml-org--embeddinggemma-2-GGUF/snapshots"
        let snaps = (try? FileManager.default.contentsOfDirectory(atPath: hub)) ?? []
        return snaps.map { hub + "/" + $0 }.first { FileManager.default.fileExists(atPath: $0 + "/" + model) }
    }()

    static let model = "embeddinggemma-2-Q8_0.gguf"
    static let vision = "mmproj-embeddinggemma-2-Q8_0.gguf"
    static var available: Bool { server != nil && dir != nil }
}

/// One llama-server child process on a free local port.
/// A small shell wrapper stops the server when this app dies, even after a crash.
final class EmbedServer {
    private let images: Bool
    private var proc: Process?
    private var port: Int32 = 0
    private var marker = ""
    private let lock = NSLock()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 180
        return URLSession(configuration: c)
    }()

    init(images: Bool) { self.images = images }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return proc?.isRunning == true }

    /// Blocks until the model is loaded. Returns false if it cannot start.
    @discardableResult func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if proc?.isRunning == true { return true }
        guard let server = ModelFiles.server, let dir = ModelFiles.dir else { return false }
        port = Self.freePort()
        var args = ["-m", dir + "/" + ModelFiles.model, "--embedding", "--pooling", "mean", "-ngl", "99",
                    "--host", "127.0.0.1", "--port", String(port), "-np", "1", "--no-webui"]
        args += images ? ["--mmproj", dir + "/" + ModelFiles.vision, "-c", "2048", "-b", "2048", "-ub", "2048"]
                       : ["-c", "512", "-b", "512", "-ub", "512"]
        let script = #""$0" "$@" & c=$!; trap 'kill $c 2>/dev/null' EXIT TERM; while kill -0 $PPID 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 2; done"#
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
                if images, let d = send("props", nil, timeout: 5),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    marker = j["media_marker"] as? String ?? ""
                }
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

    func embed(jpeg: Data) -> [Float]? {
        let content: [String: Any] = ["prompt_string": marker, "multimodal_data": [jpeg.base64EncodedString()]]
        guard let body = try? JSONSerialization.data(withJSONObject: ["content": content]) else { return nil }
        return vectors(send("embedding", body))?.first
    }
}

/// Turns a typed search into a vector. Keeps only the newest search if keys arrive faster than the model.
final class QueryEncoder {
    private let server = EmbedServer(images: false)
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
