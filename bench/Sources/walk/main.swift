// Test 1: walk the home folder with the v1 skip rules, count what would be indexed,
// and write every kept path to out/paths.txt for the name-search test.
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : home
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "out"

// Folder names that tools generate on any Mac. Hidden folders (".x") are skipped too.
let skipDirs: Set<String> = [
    "node_modules", "venv", "__pycache__", "build", "dist", "target", "DerivedData",
    "Pods", "site-packages", "bower_components", "vendor", "coverage", "out",
]
// Folders that macOS shows as one file. Index the name, never go inside.
let packageExts: Set<String> = [
    "app", "photoslibrary", "musiclibrary", "bundle", "framework", "xcodeproj",
    "xcworkspace", "plugin", "kext", "appex", "photoslibrary", "tvlibrary",
]
let skipFiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock", "Cargo.lock"]
let skipFileExts: Set<String> = ["pyc", "o", "map", "class", "lock"]
// Top-level folders in the home folder that belong to apps, not the user.
let skipTop: Set<String> = ["Library", "Applications"]

enum Kind: String, CaseIterable { case text, pdf, office, image, media, other }
func kind(_ ext: String) -> Kind {
    switch ext {
    case "txt", "md", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "html", "htm", "css",
         "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "swift", "go", "rs", "java", "kt", "c", "h",
         "cpp", "hpp", "m", "rb", "php", "sh", "zsh", "sql", "ipynb", "log", "vue", "svelte", "env",
         "ini", "conf", "tex", "rst", "srt", "vtt":
        return .text
    case "pdf": return .pdf
    case "doc", "docx", "ppt", "pptx", "xls", "xlsx", "key", "pages", "numbers", "rtf", "odt":
        return .office
    case "jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "bmp", "svg", "avif":
        return .image
    case "mp3", "m4a", "wav", "aac", "flac", "mp4", "mov", "mkv", "webm", "avi", "m4v":
        return .media
    default: return .other
    }
}

// Rough piece counts per kind (one vector per piece). These are guesses until real chunking runs.
func pieces(_ k: Kind, _ size: Int64) -> Int64 {
    switch k {
    case .text: return max(1, size / 1500)                   // ~400 tokens per passage
    case .pdf: return min(5000, max(1, size / 60_000))         // ~60 KB per page
    case .office: return max(1, size / 30_000)
    case .image: return 1
    case .media: return max(1, size / 4_000_000)               // ~30 s of audio/video
    case .other: return 0                                      // name only
    }
}

var files = [Kind: (n: Int, bytes: Int64, pieces: Int64)]()
for k in Kind.allCases { files[k] = (0, 0, 0) }
var dirs = 0, skippedDirs = 0, denied = 0, packages = 0
var paths: [String] = []
paths.reserveCapacity(1_000_000)

let t0 = Date()
let rootC = strdup(root)!
var argv: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { fatalError("fts_open failed") }
while let ent = fts_read(fts) {
    let e = ent.pointee
    let path = String(cString: e.fts_path)
    let name = (path as NSString).lastPathComponent
    switch Int32(e.fts_info) {
    case FTS_D:
        if e.fts_level == 0 { continue }
        let ext = (name as NSString).pathExtension.lowercased()
        if name.hasPrefix(".") || skipDirs.contains(name) || (e.fts_level == 1 && skipTop.contains(name)) {
            skippedDirs += 1; fts_set(fts, ent, FTS_SKIP); continue
        }
        if packageExts.contains(ext) {
            packages += 1; paths.append(path); fts_set(fts, ent, FTS_SKIP); continue
        }
        dirs += 1; paths.append(path)
    case FTS_F:
        if name.hasPrefix(".") || skipFiles.contains(name) { continue }
        let ext = (name as NSString).pathExtension.lowercased()
        if skipFileExts.contains(ext) { continue }
        let size = Int64(e.fts_statp?.pointee.st_size ?? 0)
        let k = kind(ext)
        var v = files[k]!
        v.n += 1; v.bytes += size; v.pieces += pieces(k, size)
        files[k] = v
        paths.append(path)
    case FTS_DNR, FTS_ERR:
        denied += 1
    default: break
    }
}
fts_close(fts)
let secs = Date().timeIntervalSince(t0)

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try paths.joined(separator: "\n").write(toFile: "\(outDir)/paths.txt", atomically: true, encoding: .utf8)

func mb(_ b: Int64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
print("root: \(root)")
print(String(format: "walk time: %.1f s", secs))
print("kept folders: \(dirs), packages kept as one item: \(packages), skipped folders: \(skippedDirs), unreadable: \(denied)")
var totalFiles = 0, totalPieces: Int64 = 0
for k in Kind.allCases {
    let v = files[k]!
    totalFiles += v.n; totalPieces += v.pieces
    print("\(k.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) files: \(v.n)  size: \(mb(v.bytes))  est pieces: \(v.pieces)")
}
print("total kept files: \(totalFiles), names in list: \(paths.count), est pieces: \(totalPieces)")
print(String(format: "binary index RAM at 96 B/piece: %.0f MB; int8 on disk at 768 B/piece: %.0f MB",
             Double(totalPieces) * 96 / 1_048_576, Double(totalPieces) * 768 / 1_048_576))
