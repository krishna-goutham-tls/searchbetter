import Foundation

/// Every file and folder name worth searching, held in memory.
/// Mutations and searches both run on the main thread; a search fans out across cores itself.
final class FileIndex {
    struct Hit { let id: Int; let score: Int }

    private(set) var paths: [String] = []
    private var names: [[UInt8]] = []      // lowercased file name bytes
    private var isApp: [Bool] = []
    private var modDay: [Int32] = []       // days since 1970, for the recency boost
    private var alive: [Bool] = []
    private var slot: [String: Int] = [:]  // path -> position, for updates from FSEvents
    private(set) var liveCount = 0

    let home: String
    let includeApps: Bool

    /// `root` limits the index to one folder, for demos and tests. Nil means the home folder plus apps.
    init(root: String? = nil) {
        home = root ?? FileManager.default.homeDirectoryForCurrentUser.path
        includeApps = root == nil
    }

    // MARK: Skip rules (v1 scope: LOG 2026-10-29). Patterns that are junk on any Mac.

    static let skipDirs: Set<String> = [
        "node_modules", "venv", "__pycache__", "build", "dist", "target", "DerivedData",
        "Pods", "site-packages", "bower_components", "vendor", "coverage",
    ]
    static let packageExts: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "bundle", "framework", "xcodeproj",
        "xcworkspace", "plugin", "kext", "appex", "tvlibrary",
    ]
    static let skipFiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock", "Cargo.lock"]
    static let skipFileExts: Set<String> = ["pyc", "o", "map", "class", "lock"]
    static let skipTop: Set<String> = ["Library", "Applications"]

    /// True when a path from FSEvents falls inside something the walk would skip.
    func isSkipped(_ path: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return !isAppPath(path) }
        let rel = path.dropFirst(home.count + 1).split(separator: "/")
        for (i, c) in rel.enumerated() {
            let s = String(c)
            if s.hasPrefix(".") { return true }
            if i == 0 && rel.count > 1 && Self.skipTop.contains(s) { return true }
            if i < rel.count - 1 {
                if Self.skipDirs.contains(s) { return true }
                if Self.packageExts.contains((s as NSString).pathExtension.lowercased()) { return true }
            }
        }
        let last = String(rel.last ?? "")
        if Self.skipFiles.contains(last) { return true }
        return Self.skipFileExts.contains((last as NSString).pathExtension.lowercased())
    }

    private func isAppPath(_ p: String) -> Bool {
        (p.hasPrefix("/Applications/") || p.hasPrefix("/System/Applications/")) && p.hasSuffix(".app")
    }

    // MARK: Building

    struct Entry { let path: String; let app: Bool; let day: Int32 }

    /// Walks the home folder and the app folders. Safe to call off the main thread.
    static func walk(home: String, includeApps: Bool = true) -> [Entry] {
        var out: [Entry] = []
        out.reserveCapacity(200_000)
        walkTree(home, home: home, into: &out)
        if includeApps { for root in ["/Applications", "/System/Applications"] { walkApps(root, into: &out) } }
        return out
    }

    private static func day(_ st: UnsafeMutablePointer<stat>?) -> Int32 {
        Int32((st?.pointee.st_mtimespec.tv_sec ?? 0) / 86_400)
    }

    private static func walkTree(_ root: String, home: String, into out: inout [Entry]) {
        let c = strdup(root)!
        defer { free(c) }
        var argv: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }
        while let ent = fts_read(fts) {
            let e = ent.pointee
            let path = String(cString: e.fts_path)
            let name = (path as NSString).lastPathComponent
            switch Int32(e.fts_info) {
            case FTS_D:
                if e.fts_level == 0 { continue }
                if name.hasPrefix(".") || skipDirs.contains(name)
                    || (root == home && e.fts_level == 1 && skipTop.contains(name)) {
                    fts_set(fts, ent, FTS_SKIP); continue
                }
                let ext = (name as NSString).pathExtension.lowercased()
                if packageExts.contains(ext) {
                    out.append(Entry(path: path, app: ext == "app", day: day(e.fts_statp)))
                    fts_set(fts, ent, FTS_SKIP); continue
                }
                out.append(Entry(path: path, app: false, day: day(e.fts_statp)))
            case FTS_F:
                if name.hasPrefix(".") || skipFiles.contains(name) { continue }
                if skipFileExts.contains((name as NSString).pathExtension.lowercased()) { continue }
                out.append(Entry(path: path, app: false, day: day(e.fts_statp)))
            default: break
            }
        }
    }

    /// Apps only, two levels deep (catches /System/Applications/Utilities).
    private static func walkApps(_ root: String, into out: inout [Entry]) {
        let fm = FileManager.default
        func scan(_ dir: String, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for i in items where !i.hasPrefix(".") {
                let p = dir + "/" + i
                if i.hasSuffix(".app") {
                    var st = stat()
                    lstat(p, &st)
                    out.append(Entry(path: p, app: true, day: Int32(st.st_mtimespec.tv_sec / 86_400)))
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { scan(p, depth: depth + 1) }
                }
            }
        }
        scan(root, depth: 1)
    }

    /// Replaces the whole index. Main thread.
    func load(_ entries: [Entry]) {
        paths = []; names = []; isApp = []; modDay = []; alive = []; slot = [:]
        paths.reserveCapacity(entries.count); names.reserveCapacity(entries.count)
        for e in entries { append(e) }
        liveCount = entries.count
    }

    private func append(_ e: Entry) {
        slot[e.path] = paths.count
        paths.append(e.path)
        var n = (e.path as NSString).lastPathComponent
        if e.app { n = String(n.dropLast(4)) }   // "Safari.app" is searched as "Safari"
        names.append(Array(n.lowercased().utf8))
        isApp.append(e.app)
        modDay.append(e.day)
        alive.append(true)
    }

    // MARK: Live updates

    /// Called for every path FSEvents reports. Adds, refreshes or removes it.
    func update(path: String) {
        var st = stat()
        let exists = lstat(path, &st) == 0
        if !exists || isSkipped(path) {
            if let i = slot[path], alive[i] { alive[i] = false; liveCount -= 1 }
            return
        }
        let d = Int32(st.st_mtimespec.tv_sec / 86_400)
        if let i = slot[path] {
            if !alive[i] { alive[i] = true; liveCount += 1 }
            modDay[i] = d
            return
        }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let ext = (path as NSString).pathExtension.lowercased()
        append(Entry(path: path, app: ext == "app", day: d))
        liveCount += 1
        // A folder moved in from outside arrives as one event: index what is inside it.
        if isDir && !Self.packageExts.contains(ext) && path.hasPrefix(home) {
            var inner: [Entry] = []
            Self.walkTree(path, home: home, into: &inner)
            for e in inner where slot[e.path] == nil { append(e); liveCount += 1 }
        }
    }

    // MARK: Search

    /// Every word typed must appear in the file name. Ranking: where the words match, apps first,
    /// recently changed files higher, shorter names higher.
    func search(_ query: String, limit: Int = 30) -> [Hit] {
        let tokens = query.lowercased().split(whereSeparator: { $0 == " " }).map { Array($0.utf8) }
        guard !tokens.isEmpty else { return [] }
        let whole = Array(query.lowercased().utf8)
        let today = Int32(Date().timeIntervalSince1970 / 86_400)
        let count = paths.count
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunk = (count + cores - 1) / cores
        var partial = [[Hit]](repeating: [], count: cores)

        names.withUnsafeBufferPointer { names in
        alive.withUnsafeBufferPointer { alive in
        isApp.withUnsafeBufferPointer { isApp in
        modDay.withUnsafeBufferPointer { modDay in
        partial.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: cores) { c in
                let lo = c * chunk, hi = min(count, lo + chunk)
                guard lo < hi else { return }
                var hits: [Hit] = []
                outer: for i in lo..<hi where alive[i] {
                    let n = names[i]
                    var score = 0
                    for t in tokens {
                        let m = Self.matchClass(n, t)
                        if m == 0 { continue outer }
                        score += m * 100
                    }
                    if n == whole { score += 250 }
                    if isApp[i] { score += 150 }
                    let age = Int(today - modDay[i])
                    score += max(0, 60 - age / 3)
                    score -= min(n.count, 80)
                    hits.append(Hit(id: i, score: score))
                }
                hits.sort { $0.score > $1.score }
                out[c] = Array(hits.prefix(limit))
            }
        }}}}}
        return Array(partial.joined().sorted { $0.score > $1.score }.prefix(limit))
    }

    /// 3 = name starts with the word, 2 = a word inside the name starts with it, 1 = anywhere, 0 = no match.
    @inline(__always)
    static func matchClass(_ n: [UInt8], _ q: [UInt8]) -> Int {
        let nc = n.count, qc = q.count
        if qc == 0 || nc < qc { return 0 }
        var best = 0
        var j = 0
        let first = q[0]
        while j <= nc - qc {
            if n[j] == first {
                var k = 1
                while k < qc && n[j + k] == q[k] { k += 1 }
                if k == qc {
                    if j == 0 { return 3 }
                    let p = n[j - 1]
                    let boundary = !((p >= 97 && p <= 122) || (p >= 48 && p <= 57)) || p >= 128
                    best = max(best, boundary ? 2 : 1)
                }
            }
            j += 1
        }
        return best
    }
}
