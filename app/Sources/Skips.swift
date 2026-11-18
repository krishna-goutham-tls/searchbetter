import Foundation

/// Folders whose contents SearchBetter does not read. Their file names stay searchable:
/// name search costs almost nothing, and finding a file by its name is still useful.
///
/// Two sources:
/// - folders the person skipped, from a result's menu or the menu bar (kept in UserDefaults);
/// - the markers Spotlight honours: a folder whose name ends in `.noindex`, or a folder that holds
///   a `.metadata_never_index` file. Scripts and agents can mark their own output this way.
final class Skips {
    static let shared = Skips(saved: true)
    static let marker = ".metadata_never_index"
    private static let key = "skippedFolders"

    private let saved: Bool
    private let lock = NSLock()
    private var user: [String]
    private var markers: [String: Bool] = [:]   // folder -> has a marker

    /// `saved: false` keeps the list in memory only, for the selftest.
    init(saved: Bool) {
        self.saved = saved
        user = saved ? UserDefaults.standard.stringArray(forKey: Self.key) ?? [] : []
    }

    /// The folders the person skipped, sorted.
    var folders: [String] { lock.lock(); defer { lock.unlock() }; return user.sorted() }

    func add(_ folder: String) {
        let f = Self.clean(folder)
        lock.lock()
        // A folder inside one already skipped adds nothing. A folder around skipped ones replaces them.
        if user.contains(where: { f == $0 || f.hasPrefix($0 + "/") }) { lock.unlock(); return }
        user.removeAll { $0.hasPrefix(f + "/") }
        user.append(f)
        save()
        lock.unlock()
    }

    func remove(_ folder: String) {
        lock.lock()
        user.removeAll { $0 == Self.clean(folder) }
        save()
        lock.unlock()
    }

    /// A marker file came or went. The next check reads the disk again.
    func forgetMarkers() { lock.lock(); markers.removeAll(); lock.unlock() }

    /// True when the contents of `path` stay unread. Checks the folders above it, up to `home`.
    func skipsContent(_ path: String, home: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for f in user where path == f || path.hasPrefix(f + "/") { return true }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.hasPrefix(home), dir.count > home.count {
            if hasMarker(dir) { return true }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return false
    }

    private func hasMarker(_ dir: String) -> Bool {
        if let known = markers[dir] { return known }
        let has = dir.lowercased().hasSuffix(".noindex") || access(dir + "/" + Self.marker, F_OK) == 0
        if markers.count > 200_000 { markers.removeAll() }
        markers[dir] = has
        return has
    }

    private func save() { if saved { UserDefaults.standard.set(user, forKey: Self.key) } }

    private static func clean(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
