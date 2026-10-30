import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Decides what can be read for meaning search, and reads it into pieces.
enum TextReader {
    enum Kind: Int { case text = 1, pdf = 2, image = 3 }
    struct Piece { let line: Int; let text: String }   // line is the page number in a PDF

    static let textExts: Set<String> = [
        "txt", "md", "markdown", "rst", "org", "tex", "csv", "tsv", "html", "htm", "xml", "json", "yaml", "yml", "toml",
        "ini", "conf", "sql", "swift", "py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "go", "rs", "java", "kt", "c", "h",
        "cc", "cpp", "hpp", "m", "mm", "rb", "php", "sh", "zsh", "bash", "lua", "dart", "vue", "svelte", "css", "scss",
    ]
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "gif", "bmp"]
    /// Key files stay out of the index, so their contents never reach the database or a result row.
    static let secretExts: Set<String> = ["pem", "key", "p12", "pfx", "keystore", "jks", "cer", "crt"]
    static let secretWords = ["secret", "credential", "password", "passwd", "id_rsa", "id_ed25519", "token", "apikey", "api_key", "api-key"]

    static let maxTextBytes = 1_000_000
    static let maxPieces = 200
    static let pieceChars = 1000

    static func kind(of path: String) -> Kind? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if secretExts.contains(ext) || secretWords.contains(where: name.contains) { return nil }
        if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") { return nil }
        if ext == "pdf" { return .pdf }
        if imageExts.contains(ext) { return .image }
        return textExts.contains(ext) ? .text : nil
    }

    static func read(_ path: String, kind: Kind) -> [Piece] {
        switch kind {
        case .text: return readText(path)
        case .pdf: return readPDF(path)
        case .image: return []
        }
    }

    private static func readText(_ path: String) -> [Piece] {
        guard let data = FileManager.default.contents(atPath: path), data.count <= maxTextBytes else { return [] }
        if data.prefix(8192).contains(0) { return [] }   // binary
        return split(String(decoding: data, as: UTF8.self), firstLine: 1, countLines: true)
    }

    private static func readPDF(_ path: String) -> [Piece] {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isEncrypted else { return [] }
        var out: [Piece] = []
        for i in 0..<doc.pageCount where out.count < maxPieces {
            guard let s = doc.page(at: i)?.string else { continue }
            out += split(s, firstLine: i + 1, countLines: false)
        }
        return Array(out.prefix(maxPieces))
    }

    /// Cuts on line ends, about 1000 characters per piece, and repeats the last line of each piece in the next.
    static func split(_ text: String, firstLine: Int, countLines: Bool) -> [Piece] {
        var out: [Piece] = []
        var cur = ""
        var start = firstLine
        var lineNo = firstLine
        var last = ""
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 3 { out.append(Piece(line: start, text: t)) }
            cur = ""
        }
        text.enumerateLines { raw, stop in
            var line = raw
            while line.count > pieceChars {   // one very long line
                cur += String(line.prefix(pieceChars))
                flush()
                start = lineNo
                line = String(line.dropFirst(pieceChars))
            }
            if cur.count + line.count > pieceChars {
                flush()
                start = countLines ? max(firstLine, lineNo - 1) : firstLine
                if last.count < 200 { cur = last + "\n" }
            }
            if cur.isEmpty { start = countLines ? lineNo : firstLine }
            cur += line + "\n"
            last = line
            if countLines { lineNo += 1 }
            if out.count >= maxPieces { stop = true }
        }
        if out.count < maxPieces { flush() }
        return Array(out.prefix(maxPieces))
    }

    /// Returns a JPEG for the model and a small JPEG for the result row. Nil for small images such as icons.
    static func prepareImage(_ path: String) -> (forModel: Data, thumb: Data)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              min(w, h) >= 160, max(w, h) >= 300 else { return nil }
        guard let big = jpeg(src, maxPixels: 768, quality: 0.85), let small = jpeg(src, maxPixels: 240, quality: 0.7) else { return nil }
        return (big, small)
    }

    private static func jpeg(_ src: CGImageSource, maxPixels: Int, quality: Double) -> Data? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
