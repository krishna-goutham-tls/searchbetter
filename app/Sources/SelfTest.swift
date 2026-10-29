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

        print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
        return failures == 0 ? 0 : 1
    }
}
