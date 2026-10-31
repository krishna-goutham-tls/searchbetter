import CryptoKit
import Foundation

/// Downloads the model into `ModelFiles.ownDir`. A stopped download continues from where it stopped,
/// also after the app quits. The app uses the file only when its SHA-256 matches.
final class ModelDownload: NSObject, URLSessionDataDelegate {
    /// A copy of ggml-org/embeddinggemma-2-GGUF, revision 58faf90. It sits on its own release, so its count
    /// stays in one place across app versions. The count gives a rough number of first opens.
    static let url = URL(string: "https://github.com/krishna-goutham-tls/searchbetter/releases/download/model-v1/\(ModelFiles.model)")!
    static let size: Int64 = 309_855_456
    static let sha256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
    /// The model, plus room for the index of a normal Mac.
    static let freeSpaceNeeded: Int64 = 1_000_000_000

    enum Failure { case noSpace, network, damaged }

    /// All on the main thread.
    var onProgress: ((Int64) -> Void)?
    var onFinish: ((Failure?) -> Void)?

    private var session: URLSession?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var lastReport = Date.distantPast
    private var activity: NSObjectProtocol?
    private var part: String { ModelFiles.ownDir + "/" + ModelFiles.model + ".part" }
    private var final: String { ModelFiles.ownDir + "/" + ModelFiles.model }

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: ModelFiles.ownDir, withIntermediateDirectories: true)
        received = ((try? fm.attributesOfItem(atPath: part))?[.size] as? Int64) ?? 0
        let free = (try? URL(fileURLWithPath: ModelFiles.ownDir).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        guard free >= Self.freeSpaceNeeded - received else { finish(.noSpace); return }

        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Downloading the search model")
        if received >= Self.size { verify(); return }

        if !fm.fileExists(atPath: part) { fm.createFile(atPath: part, contents: nil) }
        file = FileHandle(forWritingAtPath: part)
        file?.seekToEndOfFile()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s
        var request = URLRequest(url: Self.url)
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        s.dataTask(with: request).resume()
        report(force: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        switch (response as? HTTPURLResponse)?.statusCode {
        case 206:
            completionHandler(.allow)
        case 200:
            // The server ignored the range and sends the whole file again.
            file?.truncateFile(atOffset: 0)
            received = 0
            completionHandler(.allow)
        default:
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            report(force: false)
        } catch {
            dataTask.cancel()   // disk full: the completion below reports it as stopped
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close()
        file = nil
        session.finishTasksAndInvalidate()
        if error != nil || received < Self.size { finish(.network) } else { verify() }
    }

    private func report(force: Bool) {
        guard force || Date().timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = Date()
        let n = received
        DispatchQueue.main.async { self.onProgress?(n) }
    }

    private func verify() {
        report(force: true)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard Self.hash(part) == Self.sha256 else {
                try? FileManager.default.removeItem(atPath: part)
                finish(.damaged)
                return
            }
            do {
                try FileManager.default.moveItem(atPath: part, toPath: final)
                finish(nil)
            } catch {
                finish(.damaged)
            }
        }
    }

    private static func hash(_ path: String) -> String? {
        guard let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        var h = SHA256()
        while let d = try? f.read(upToCount: 4 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func finish(_ failure: Failure?) {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        DispatchQueue.main.async { self.onFinish?(failure) }
    }
}
