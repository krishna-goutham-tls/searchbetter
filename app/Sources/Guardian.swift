import AppKit

/// Reopens the app after a crash. A memory crash cannot be caught from inside the process,
/// so a small helper process watches from outside. A normal quit leaves a marker and the helper stays quiet.
enum Guardian {
    private static let startsKey = "guardian.recentStarts"
    private static let window: TimeInterval = 600
    private static let maxStarts = 3
    private static let marker = NSTemporaryDirectory() + "mac-search-clean-\(getpid())"
    private static var term: DispatchSourceSignal?

    static func start(root: String?) {
        // SIGTERM is a normal request to quit. Without this it kills the process and looks like a crash.
        signal(SIGTERM, SIG_IGN)
        let t = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        t.setEventHandler { NSApp.terminate(nil) }
        t.resume()
        term = t

        // A crash that repeats on every start must not loop forever.
        let now = Date().timeIntervalSince1970
        let starts = (UserDefaults.standard.array(forKey: startsKey) as? [Double] ?? []).filter { now - $0 < window } + [now]
        UserDefaults.standard.set(starts, forKey: startsKey)
        guard starts.count <= maxStarts else { return }

        let script = #"while kill -0 $PPID 2>/dev/null; do sleep 1; done; if [ -e "$1" ]; then rm -f "$1"; else shift; open "$@"; fi"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "guardian", marker, Bundle.main.bundlePath] + ["--args", "--restarted"] + (root.map { ["--root", $0] } ?? [])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    static func cleanExit() {
        FileManager.default.createFile(atPath: marker, contents: nil)
        UserDefaults.standard.removeObject(forKey: startsKey)
    }
}
