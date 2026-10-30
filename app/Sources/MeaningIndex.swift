import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The index behind meaning search and exact-word search.
/// SQLite holds everything on disk. Binary and int8 vectors also live in RAM, so a scan never reads the disk.
final class MeaningIndex {
    struct Hit { let fileID: Int32; let pieceID: Int64; let score: Float; let isImage: Bool }
    struct Exact { let fileID: Int32; let pieceID: Int64; let rank: Double }

    /// One file to store. A nil vector means exact-word search only, for now.
    struct Row {
        let path: String; let mtime: Int64; let size: Int64; let kind: TextReader.Kind
        var pieces: [(line: Int, text: String, vector: [Float]?)] = []
        var thumb: Data? = nil
        var stage = 0   // 0: waiting for its first vector, 1: searchable by meaning
    }
    /// A file waiting for its first vector, with the start of its text.
    struct Pending { let fileID: Int32; let path: String; let mtime: Int64; let kind: TextReader.Kind; let pieceID: Int64?; let head: String }
    struct DeepPiece { let pieceID: Int64; let fileID: Int32; let path: String; let text: String }

    static let dim = 768
    static let words = 12              // 768 bits as 12 UInt64
    static let int8Scale: Float = 500  // vectors are unit length, so components stay small

    private var db: OpaquePointer?     // use only inside writer.sync: statements and transactions must not overlap
    private let writer = DispatchQueue(label: "mac-search.writer", qos: .utility)
    private var reader: OpaquePointer? // exact-word searches and row details
    private let readerQueue = DispatchQueue(label: "mac-search.reader", qos: .userInteractive)

    private var rw = pthread_rwlock_t()
    private var bin: [UInt64] = []
    private var i8: [Int8] = []
    private var pieceIDs: [Int64] = []
    private var fileOf: [Int32] = []
    private var image: [Bool] = []
    private var alive: [Bool] = []
    private var slots: [Int32: [Int]] = [:]
    private var paths: [Int32: String] = [:]
    private var liveCount = 0

    init?(dir: String) {
        pthread_rwlock_init(&rw, nil)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = dir + "/index-v2.sqlite"
        for old in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"] { try? FileManager.default.removeItem(atPath: dir + "/" + old) }
        guard sqlite3_open(file, &db) == SQLITE_OK else { return nil }
        chmod(file, 0o600)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, path TEXT UNIQUE, mtime INTEGER, size INTEGER, kind INTEGER, stage INTEGER, thumb BLOB);
            CREATE TABLE IF NOT EXISTS pieces(id INTEGER PRIMARY KEY, file_id INTEGER, line INTEGER, text TEXT, vec BLOB);
            CREATE INDEX IF NOT EXISTS pieces_file ON pieces(file_id);
            CREATE INDEX IF NOT EXISTS pieces_no_vector ON pieces(file_id) WHERE vec IS NULL;
            CREATE INDEX IF NOT EXISTS files_stage ON files(stage);
            CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(text, content='pieces', content_rowid='id',
                tokenize='porter unicode61 remove_diacritics 2', prefix='2 3 4');
            CREATE TRIGGER IF NOT EXISTS pieces_ai AFTER INSERT ON pieces BEGIN
                INSERT INTO words(rowid, text) VALUES (new.id, new.text); END;
            CREATE TRIGGER IF NOT EXISTS pieces_ad AFTER DELETE ON pieces BEGIN
                INSERT INTO words(words, rowid, text) VALUES ('delete', old.id, old.text); END;
            """)
        guard sqlite3_open_v2(file, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        loadIntoRAM()
    }

    deinit { sqlite3_close(db); sqlite3_close(reader) }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func loadIntoRAM() {
        var s: OpaquePointer?
        sqlite3_prepare_v2(reader, "SELECT id, path, kind FROM files", -1, &s, nil)
        var kinds: [Int32: Int32] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let id = sqlite3_column_int(s, 0)
            paths[id] = String(cString: sqlite3_column_text(s, 1))
            kinds[id] = sqlite3_column_int(s, 2)
        }
        sqlite3_finalize(s)
        sqlite3_prepare_v2(reader, "SELECT id, file_id, vec FROM pieces WHERE vec IS NOT NULL", -1, &s, nil)
        while sqlite3_step(s) == SQLITE_ROW {
            guard sqlite3_column_bytes(s, 2) == Self.dim, let b = sqlite3_column_blob(s, 2) else { continue }
            let fid = sqlite3_column_int(s, 1)
            let v = UnsafeBufferPointer(start: b.assumingMemoryBound(to: Int8.self), count: Self.dim)
            addToRAM(id: sqlite3_column_int64(s, 0), file: fid, isImage: kinds[fid] == 3, vec: v)
        }
        sqlite3_finalize(s)
    }

    private func addToRAM(id: Int64, file: Int32, isImage: Bool, vec: UnsafeBufferPointer<Int8>) {
        slots[file, default: []].append(pieceIDs.count)
        pieceIDs.append(id); fileOf.append(file); image.append(isImage); alive.append(true)
        i8.append(contentsOf: vec)
        var w = [UInt64](repeating: 0, count: Self.words)
        for i in 0..<Self.dim where vec[i] > 0 { w[i / 64] |= 1 << UInt64(i % 64) }
        bin.append(contentsOf: w)
        liveCount += 1
    }

    var pieceCount: Int { pthread_rwlock_rdlock(&rw); defer { pthread_rwlock_unlock(&rw) }; return liveCount }

    func path(of file: Int32) -> String? { pthread_rwlock_rdlock(&rw); defer { pthread_rwlock_unlock(&rw) }; return paths[file] }

    // MARK: Writing

    /// path -> mtime and size of what the index holds now.
    func known() -> [String: (mtime: Int64, size: Int64)] {
        writer.sync {
            var out: [String: (mtime: Int64, size: Int64)] = [:]
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT path, mtime, size FROM files", -1, &s, nil)
            while sqlite3_step(s) == SQLITE_ROW {
                out[String(cString: sqlite3_column_text(s, 0))] = (sqlite3_column_int64(s, 1), sqlite3_column_int64(s, 2))
            }
            sqlite3_finalize(s)
            return out
        }
    }

    /// Replaces each file in one transaction. Batches make the words pass fast.
    func putAll(_ rows: [Row]) {
        writer.sync {
            var ram: [(file: Int32, kind: TextReader.Kind, path: String, id: Int64, vec: [Int8])] = []
            var fresh: [(Int32, String)] = []
            var dropped: [Int32] = []
            exec("BEGIN")
            var f: OpaquePointer?, p: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO files(path, mtime, size, kind, stage, thumb) VALUES(?,?,?,?,?,?)", -1, &f, nil)
            sqlite3_prepare_v2(db, "INSERT INTO pieces(file_id, line, text, vec) VALUES(?,?,?,?)", -1, &p, nil)
            for r in rows {
                if let old = fileID(r.path) { deleteRows(old); dropped.append(old) }
                sqlite3_reset(f); sqlite3_clear_bindings(f)
                sqlite3_bind_text(f, 1, r.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(f, 2, r.mtime); sqlite3_bind_int64(f, 3, r.size)
                sqlite3_bind_int(f, 4, Int32(r.kind.rawValue)); sqlite3_bind_int(f, 5, Int32(r.stage))
                if let t = r.thumb { t.withUnsafeBytes { _ = sqlite3_bind_blob(f, 6, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) } }
                sqlite3_step(f)
                let fid = Int32(sqlite3_last_insert_rowid(db))
                fresh.append((fid, r.path))
                for piece in r.pieces {
                    sqlite3_reset(p); sqlite3_clear_bindings(p)
                    sqlite3_bind_int(p, 1, fid); sqlite3_bind_int(p, 2, Int32(piece.line))
                    sqlite3_bind_text(p, 3, piece.text, -1, SQLITE_TRANSIENT)
                    let v = piece.vector.map(Self.quantize)
                    if let v { v.withUnsafeBytes { _ = sqlite3_bind_blob(p, 4, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) } }
                    sqlite3_step(p)
                    if let v { ram.append((fid, r.kind, r.path, sqlite3_last_insert_rowid(db), v)) }
                }
            }
            sqlite3_finalize(f); sqlite3_finalize(p)
            exec("COMMIT")
            pthread_rwlock_wrlock(&rw)
            for d in dropped { dropFromRAM(d) }
            for (id, path) in fresh { paths[id] = path }
            for r in ram { r.vec.withUnsafeBufferPointer { addToRAM(id: r.id, file: r.file, isImage: r.kind == .image, vec: $0) } }
            pthread_rwlock_unlock(&rw)
        }
    }

    func put(path: String, mtime: Int64, size: Int64, kind: TextReader.Kind,
             pieces: [(line: Int, text: String, vector: [Float])], thumb: Data?) {
        putAll([Row(path: path, mtime: mtime, size: size, kind: kind,
                    pieces: pieces.map { ($0.line, $0.text, $0.vector) }, thumb: thumb, stage: 1)])
    }

    func remove(path: String) {
        writer.sync {
            guard let id = fileID(path) else { return }
            exec("BEGIN"); deleteRows(id); exec("COMMIT")
            pthread_rwlock_wrlock(&rw); dropFromRAM(id); pthread_rwlock_unlock(&rw)
        }
    }

    /// Every file still waiting for its first vector.
    func pending(path: String? = nil) -> [Pending] {
        writer.sync {
            var s: OpaquePointer?
            let sql = """
                SELECT f.id, f.path, f.mtime, f.kind, p.id, substr(p.text, 1, \(Self.headChars)) FROM files f
                LEFT JOIN pieces p ON p.id = (SELECT min(id) FROM pieces WHERE file_id = f.id)
                WHERE f.stage = 0 \(path == nil ? "" : "AND f.path = ?")
                """
            sqlite3_prepare_v2(db, sql, -1, &s, nil)
            if let path { sqlite3_bind_text(s, 1, path, -1, SQLITE_TRANSIENT) }
            var out: [Pending] = []
            while sqlite3_step(s) == SQLITE_ROW {
                let piece: Int64? = sqlite3_column_type(s, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 4)
                let head = sqlite3_column_text(s, 5).map { String(cString: $0) } ?? ""
                out.append(Pending(fileID: sqlite3_column_int(s, 0), path: String(cString: sqlite3_column_text(s, 1)),
                                   mtime: sqlite3_column_int64(s, 2), kind: TextReader.Kind(rawValue: Int(sqlite3_column_int(s, 3))) ?? .code,
                                   pieceID: piece, head: head))
            }
            sqlite3_finalize(s)
            return out
        }
    }

    static let headChars = 500

    /// Pieces of notes and PDFs not yet read in full, newest first.
    func pendingDeep(limit: Int) -> [DeepPiece] {
        writer.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, """
                SELECT p.id, p.file_id, f.path, p.text FROM pieces p JOIN files f ON f.id = p.file_id
                WHERE p.vec IS NULL AND f.stage = 1 AND f.kind IN (2, 4) ORDER BY f.mtime DESC LIMIT \(limit)
                """, -1, &s, nil)
            var out: [DeepPiece] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(DeepPiece(pieceID: sqlite3_column_int64(s, 0), fileID: sqlite3_column_int(s, 1),
                                     path: String(cString: sqlite3_column_text(s, 2)), text: String(cString: sqlite3_column_text(s, 3))))
            }
            sqlite3_finalize(s)
            return out
        }
    }

    func deepCount() -> Int {
        writer.sync {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT count(*) FROM pieces p JOIN files f ON f.id = p.file_id WHERE p.vec IS NULL AND f.stage = 1 AND f.kind IN (2, 4)", -1, &s, nil)
            defer { sqlite3_finalize(s) }
            return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
        }
    }

    /// Stores vectors for existing pieces and marks files as searchable by meaning.
    /// A nil vector means the model refused that piece: an empty value stops it coming back.
    func finish(vectors: [(pieceID: Int64, fileID: Int32, vector: [Float]?)], files: [Int32]) {
        writer.sync {
            exec("BEGIN")
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "UPDATE pieces SET vec = ? WHERE id = ?", -1, &s, nil)
            var ram: [(Int64, Int32, [Int8])] = []
            for v in vectors {
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                if let f = v.vector {
                    let q = Self.quantize(f)
                    q.withUnsafeBytes { _ = sqlite3_bind_blob(s, 1, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
                    ram.append((v.pieceID, v.fileID, q))
                } else { sqlite3_bind_zeroblob(s, 1, 0) }
                sqlite3_bind_int64(s, 2, v.pieceID)
                sqlite3_step(s)
            }
            sqlite3_finalize(s)
            for f in files { exec("UPDATE files SET stage = 1 WHERE id = \(f)") }
            exec("COMMIT")
            pthread_rwlock_wrlock(&rw)
            for (id, file, q) in ram where paths[file] != nil {
                q.withUnsafeBufferPointer { addToRAM(id: id, file: file, isImage: false, vec: $0) }
            }
            pthread_rwlock_unlock(&rw)
        }
    }

    /// Stores what an image shows. Nil description means a small image such as an icon.
    func finishImage(fileID: Int32, text: String?, vector: [Float]?, thumb: Data?) {
        writer.sync {
            exec("BEGIN")
            var pid: Int64?
            var q: [Int8]?
            if let text, let vector {
                let v = Self.quantize(vector)
                var s: OpaquePointer?
                sqlite3_prepare_v2(db, "INSERT INTO pieces(file_id, line, text, vec) VALUES(?,0,?,?)", -1, &s, nil)
                sqlite3_bind_int(s, 1, fileID)
                sqlite3_bind_text(s, 2, text, -1, SQLITE_TRANSIENT)
                v.withUnsafeBytes { _ = sqlite3_bind_blob(s, 3, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
                sqlite3_step(s); sqlite3_finalize(s)
                pid = sqlite3_last_insert_rowid(db); q = v
            }
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "UPDATE files SET stage = 1, thumb = ? WHERE id = ?", -1, &s, nil)
            if let thumb { thumb.withUnsafeBytes { _ = sqlite3_bind_blob(s, 1, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) } }
            sqlite3_bind_int(s, 2, fileID)
            sqlite3_step(s); sqlite3_finalize(s)
            exec("COMMIT")
            if let pid, let q {
                pthread_rwlock_wrlock(&rw)
                if paths[fileID] != nil { q.withUnsafeBufferPointer { addToRAM(id: pid, file: fileID, isImage: true, vec: $0) } }
                pthread_rwlock_unlock(&rw)
            }
        }
    }

    private func fileID(_ path: String) -> Int32? {
        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM files WHERE path=?", -1, &s, nil)
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, path, -1, SQLITE_TRANSIENT)
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int(s, 0) : nil
    }

    private func deleteRows(_ id: Int32) {
        exec("DELETE FROM pieces WHERE file_id=\(id); DELETE FROM files WHERE id=\(id);")
    }

    private func dropFromRAM(_ id: Int32) {
        for i in slots[id] ?? [] where alive[i] { alive[i] = false; liveCount -= 1 }
        slots[id] = nil
        paths[id] = nil
    }

    static func quantize(_ v: [Float]) -> [Int8] {
        v.map { Int8(max(-127, min(127, ($0 * int8Scale).rounded()))) }
    }

    // MARK: Meaning search

    /// Scans every binary vector, then re-checks the closest ones with int8 vectors.
    /// Text and images are ranked apart because their scores sit at different levels.
    func search(_ q: [Float], topFiles: Int = 30) -> (text: [Hit], images: [Hit]) {
        let qi = Self.quantize(q)
        var qb = [UInt64](repeating: 0, count: Self.words)
        for i in 0..<Self.dim where qi[i] > 0 { qb[i / 64] |= 1 << UInt64(i % 64) }

        pthread_rwlock_rdlock(&rw); defer { pthread_rwlock_unlock(&rw) }
        let n = pieceIDs.count
        guard n > 0 else { return ([], []) }
        var dist = [UInt16](repeating: 0, count: n)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunk = (n + cores - 1) / cores
        let w = Self.words
        bin.withUnsafeBufferPointer { b in
        qb.withUnsafeBufferPointer { qq in
        alive.withUnsafeBufferPointer { a in
        dist.withUnsafeMutableBufferPointer { d in
            let dp = d.baseAddress!
            DispatchQueue.concurrentPerform(iterations: cores) { c in
                let lo = c * chunk, hi = min(n, lo + chunk)
                guard lo < hi else { return }
                for i in lo..<hi {
                    if !a[i] { dp[i] = .max; continue }
                    var s = 0
                    let row = i * w
                    for k in 0..<w { s &+= (b[row + k] ^ qq[k]).nonzeroBitCount }
                    dp[i] = UInt16(truncatingIfNeeded: s)
                }
            }
        }}}}
        return (rerank(q: qi, dist: dist, wantImages: false, keep: 400, topFiles: topFiles),
                rerank(q: qi, dist: dist, wantImages: true, keep: 150, topFiles: topFiles))
    }

    private func rerank(q: [Int8], dist: [UInt16], wantImages: Bool, keep: Int, topFiles: Int) -> [Hit] {
        var hist = [Int](repeating: 0, count: Self.dim + 1)
        var count = 0
        for i in 0..<dist.count where dist[i] != .max && image[i] == wantImages { hist[Int(dist[i])] += 1; count += 1 }
        guard count > 0 else { return [] }
        var cut = 0, seen = 0
        while cut < Self.dim && seen + hist[cut] < keep { seen += hist[cut]; cut += 1 }

        let scale = Self.int8Scale * Self.int8Scale
        var best: [Int32: Hit] = [:]
        i8.withUnsafeBufferPointer { v in
        q.withUnsafeBufferPointer { qq in
            for i in 0..<dist.count where Int(dist[i]) <= cut && dist[i] != .max && image[i] == wantImages {
                var dot: Int32 = 0
                let row = i * Self.dim
                for k in 0..<Self.dim { dot &+= Int32(v[row + k]) &* Int32(qq[k]) }
                let score = Float(dot) / scale
                if score > (best[fileOf[i]]?.score ?? -2) {
                    best[fileOf[i]] = Hit(fileID: fileOf[i], pieceID: pieceIDs[i], score: score, isImage: wantImages)
                }
            }
        }}
        return Array(best.values.sorted { $0.score > $1.score }.prefix(topFiles))
    }

    // MARK: Exact words

    /// Every word must appear in the piece. The last word may be half typed.
    func exact(_ query: String, limit: Int = 30, done: @escaping ([Exact]) -> Void) {
        let toks = query.lowercased().unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String($0) }
        guard !toks.isEmpty else { done([]); return }
        let match = toks.enumerated().map { "\"\($1)\"" + ($0 == toks.count - 1 && $1.count >= 3 ? "*" : "") }.joined(separator: " ")
        let phrase = toks.count > 1 ? "\"\(toks.joined(separator: " "))\"" : nil
        readerQueue.async { [self] in
            // Ranking every match of a common word takes over 500 ms on a large index. Such a word tells
            // little anyway, so only a phrase counts then, and meaning search does the rest.
            if count(match) < Self.commonLimit { done(ranked(match, limit)); return }
            if let phrase, count(phrase) < Self.commonLimit { done(ranked(phrase, limit)); return }
            done([])
        }
    }

    static let commonLimit = 500

    private func count(_ match: String) -> Int {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(reader, "SELECT rowid FROM words WHERE words MATCH ? LIMIT \(Self.commonLimit)", -1, &s, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(s, 1, match, -1, SQLITE_TRANSIENT)
        var n = 0
        while sqlite3_step(s) == SQLITE_ROW { n += 1 }
        return n
    }

    private func ranked(_ match: String, _ limit: Int) -> [Exact] {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        let sql = "SELECT p.file_id, w.rowid, w.rank FROM words w JOIN pieces p ON p.id = w.rowid WHERE words MATCH ? ORDER BY w.rank LIMIT 200"
        guard sqlite3_prepare_v2(reader, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(s, 1, match, -1, SQLITE_TRANSIENT)
        var out: [Exact] = []
        var seen = Set<Int32>()
        while sqlite3_step(s) == SQLITE_ROW && out.count < limit {
            let f = sqlite3_column_int(s, 0)
            if seen.insert(f).inserted { out.append(Exact(fileID: f, pieceID: sqlite3_column_int64(s, 1), rank: sqlite3_column_double(s, 2))) }
        }
        return out
    }

    // MARK: Row details

    func piece(_ id: Int64) -> (line: Int, text: String)? {
        var s: OpaquePointer?
        sqlite3_prepare_v2(reader, "SELECT line, text FROM pieces WHERE id=?", -1, &s, nil)
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, id)
        guard sqlite3_step(s) == SQLITE_ROW, let t = sqlite3_column_text(s, 1) else { return nil }
        return (Int(sqlite3_column_int(s, 0)), String(cString: t))
    }

    func thumb(path: String) -> Data? {
        var s: OpaquePointer?
        sqlite3_prepare_v2(reader, "SELECT thumb FROM files WHERE path=?", -1, &s, nil)
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(s) == SQLITE_ROW, let b = sqlite3_column_blob(s, 0) else { return nil }
        return Data(bytes: b, count: Int(sqlite3_column_bytes(s, 0)))
    }

}
