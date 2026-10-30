import AppKit

/// `--index` fills the index and exits. `--query q` and `--queries file` print results and times.
/// Neither opens the search box.
enum Cli {
    static func run(root: String?) -> Never {
        setlinebuf(stdout)
        let engine = Engine(root: root)
        let t0 = Date()
        engine.files.load(FileIndex.walk(home: engine.files.home, includeApps: engine.files.includeApps))
        print("files: \(engine.files.liveCount) under \(engine.files.home)")
        DispatchQueue.global().async {
            guard engine.openMeaning() else { print("model or llama-server not found"); exit(1) }
            print("index: \(engine.meaning!.pieceCount) pieces loaded")
            if args.contains("--index") { fill(engine, t0) }
            DispatchQueue.main.async { runQueries(engine) }
        }
        dispatchMain()
    }

    /// Draws the panel with results into a PNG. The window stays off screen and never takes the keyboard.
    static func render(root: String?, query: String, to out: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let engine = Engine(root: root)
        engine.files.load(FileIndex.walk(home: engine.files.home, includeApps: engine.files.includeApps))
        DispatchQueue.global().async {
            guard engine.openMeaning() else { exit(1) }
            DispatchQueue.main.async {
                let panel = SearchPanel(engine: engine)
                panel.indexing = false
                engine.search("warm up query") { _, final in
                    guard final else { return }
                    panel.render(query) {
                        panel.snapshot(to: out)
                        engine.shutdown()
                        usleep(300_000)
                        exit(0)
                    }
                }
            }
        }
        app.run()
        exit(0)
    }

    private static func fill(_ engine: Engine, _ t0: Date) {
        let idx = engine.indexer!
        idx.onPhaseDone = { name, secs in print(String(format: "  %@: %.0f s", name, secs)) }
        DispatchQueue.main.sync { idx.start(paths: engine.files.paths) }
        var last = Date()
        while !idx.isFinished {
            usleep(200_000)
            if Date().timeIntervalSince(last) > 15 {
                print("  \(idx.status), \(engine.meaning!.pieceCount) vectors, \(Int(Date().timeIntervalSince(t0))) s")
                last = Date()
            }
        }
        print(String(format: "indexed: %d vectors in %.0f s", engine.meaning!.pieceCount, Date().timeIntervalSince(t0)))
        engine.indexer!.stop()
    }

    private static func runQueries(_ engine: Engine) {
        var queries: [String] = []
        for (i, a) in args.enumerated() where a == "--query" && i + 1 < args.count { queries.append(args[i + 1]) }
        if let f = argValue("--queries"), let s = try? String(contentsOfFile: f, encoding: .utf8) {
            queries += s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        // Let the query model finish loading, so the first time is not a load time.
        engine.search("warm up query") { _, final in if final { next(engine, queries[...], []) } }
    }

    private static func next(_ engine: Engine, _ rest: ArraySlice<String>, _ times: [Double]) {
        guard let q = rest.first else {
            if !times.isEmpty {
                let s = times.sorted()
                print(String(format: "search: median %.1f ms, p95 %.1f ms, max %.1f ms (%d searches)",
                             s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))], s.last!, s.count))
            }
            engine.shutdown()
            usleep(300_000)
            exit(0)
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        engine.search(q) { rows, final in
            guard final else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            print(String(format: "\n> %@   (%.1f ms)", q, ms))
            for r in rows.prefix(args.contains("--brief") ? 3 : 8) {
                let short = r.path.replacingOccurrences(of: engine.files.home, with: "")
                print(String(format: "  %.4f %@  [%@]", r.score, short, r.debug))
                if !args.contains("--brief"), let s = engine.snippet(for: r) { print("         \(s)") }
            }
            next(engine, rest.dropFirst(), times + [ms])
        }
    }
}
