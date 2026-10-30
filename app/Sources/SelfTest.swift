import Foundation

/// `mac-search --selftest`: builds the index, types sample searches one key at a time,
/// checks live updates, and prints times. Exit code 0 means every check passed.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ msg: String) { print((ok ? "ok   " : "FAIL ") + msg); if !ok { failures += 1 } }
        func ms(_ t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }

        // Ranking on fixed names.
        check(FileIndex.matchClass(Array("readme.md".utf8), Array("read".utf8)) == 3, "match: start of name")
        check(FileIndex.matchClass(Array("project-readme.md".utf8), Array("read".utf8)) == 2, "match: start of a word")
        check(FileIndex.matchClass(Array("thread.swift".utf8), Array("read".utf8)) == 1, "match: inside a word")
        check(FileIndex.matchClass(Array("notes.txt".utf8), Array("read".utf8)) == 0, "match: none")

        let idx = FileIndex()
        check(idx.isSkipped(idx.home + "/x/node_modules/a.js"), "skip: node_modules")
        check(idx.isSkipped(idx.home + "/x/.git/HEAD"), "skip: hidden folder")
        check(idx.isSkipped(idx.home + "/Library/Caches/a"), "skip: ~/Library")
        check(!idx.isSkipped(idx.home + "/Desktop/notes.md"), "keep: Desktop file")

        var t0 = DispatchTime.now().uptimeNanoseconds
        let entries = FileIndex.walk(home: idx.home)
        idx.load(entries)
        print(String(format: "index: %d items in %.0f ms", idx.liveCount, ms(t0)))
        check(idx.liveCount > 1000, "index has more than 1000 items")

        let safari = idx.search("safari").first.map { idx.paths[$0.id] } ?? ""
        check(safari.hasSuffix("Safari.app"), "\"safari\" puts Safari.app first (got \(safari))")

        // Per keystroke timing.
        var times: [Double] = []
        for q in ["invoice", "readme", "screenshot", "agents md", "pricing", "lidawake", "budget 2026", "whiteboard"] {
            for n in 1...q.count {
                t0 = DispatchTime.now().uptimeNanoseconds
                _ = idx.search(String(q.prefix(n)))
                times.append(ms(t0))
            }
        }
        times.sort()
        print(String(format: "search per keystroke: median %.2f ms, p95 %.2f ms, max %.2f ms (%d keystrokes)",
                     times[times.count / 2], times[Int(Double(times.count) * 0.95)], times.last!, times.count))
        check(times[Int(Double(times.count) * 0.95)] < 20, "p95 under 20 ms")

        // Live update: a new file appears, then disappears.
        let name = "macsearch-selftest-\(Int.random(in: 100_000...999_999)).txt"
        let path = idx.home + "/Desktop/" + name
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        idx.update(path: path)
        check(idx.search(name).first.map { idx.paths[$0.id] } == path, "new file is found after update")
        try? FileManager.default.removeItem(atPath: path)
        idx.update(path: path)
        check(idx.search(name).isEmpty, "deleted file is gone after update")

        // Reading files into pieces.
        check(TextReader.kind(of: "/x/notes.md") == .text && TextReader.kind(of: "/x/a.pdf") == .pdf && TextReader.kind(of: "/x/a.HEIC") == .image, "kinds: text, pdf, image")
        check(TextReader.kind(of: "/x/server.pem") == nil && TextReader.kind(of: "/x/api_key.txt") == nil && TextReader.kind(of: "/x/passwords.csv") == nil, "key and password files stay out of the index")
        let long = (1...500).map { "line number \($0) with some words" }.joined(separator: "\n")
        let parts = TextReader.split(long, firstLine: 1, countLines: true)
        check(parts.count > 5 && parts.allSatisfy { $0.text.count <= TextReader.pieceChars + 300 }, "split: pieces stay near the size limit")
        check(parts[3].text.hasPrefix("line number \(parts[3].line) "), "split: a piece knows its first line")
        check(MeaningIndex.quantize([0.1, -0.1, 2]) == [50, -50, 127], "quantize: scale and clamp")
        meaningChecks(check)

        print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
        return failures == 0 ? 0 : 1
    }

    /// Index a temporary folder with the real model: meaning, exact words, change and delete.
    private static func meaningChecks(_ check: (Bool, String) -> Void) {
        guard ModelFiles.available else { print("skip: model not on this Mac"); return }
        let dir = NSTemporaryDirectory() + "macsearch-selftest-\(Int.random(in: 100_000...999_999))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let m = MeaningIndex(dir: dir + "/db") else { check(false, "index opens"); return }
        let server = EmbedServer(images: false)
        defer { server.stop() }
        check(server.start(), "model server starts")
        func put(_ name: String, _ text: String) {
            let v = server.embed(texts: ["title: \(name) | text: \(text)"])!.first!
            m.put(path: dir + "/" + name, mtime: 1, size: 1, kind: .text, pieces: [(1, text, v)], thumb: nil)
        }
        func top(_ q: String) -> String {
            let v = server.embed(texts: ["task: search result | query: " + q])!.first!
            return m.search(v).text.first.flatMap { m.path(of: $0.fileID) }.map { ($0 as NSString).lastPathComponent } ?? ""
        }
        func exact(_ q: String) -> Int {
            let s = DispatchSemaphore(value: 0)
            var n = 0
            m.exact(q) { n = $0.count; s.signal() }
            s.wait()
            return n
        }
        put("a.txt", "We give customers their money back within 30 days of purchase.")
        put("b.txt", "The oven in the second kitchen trips the circuit breaker every morning.")
        check(top("how long do people have to return things") == "a.txt", "meaning: finds a file without the same words")
        check(top("why does the electricity cut out when baking") == "b.txt", "meaning: second file")
        check(exact("circuit brea") == 1, "exact words: half-typed last word")
        put("a.txt", "Our mountain cabin has two bedrooms and a stove.")
        check(exact("purchase") == 0 && exact("cabin") == 1, "change: old words go, new words come")
        check(top("house in the hills") == "a.txt", "change: new meaning found")
        m.remove(path: dir + "/a.txt")
        check(m.pieceCount == 1 && top("house in the hills") == "b.txt", "delete: file leaves the search")
        var t: [Double] = []
        let q = server.embed(texts: ["task: search result | query: test"])!.first!
        for _ in 0..<50 { let t0 = DispatchTime.now().uptimeNanoseconds; _ = m.search(q); t.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
        print(String(format: "scan: median %.3f ms", t.sorted()[25]))
    }
}
