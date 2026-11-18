// Updater.swift - shared by every thelaunch.space Mac app. The copy in mac-release/repo/updater/
// is the source; updater/sync.sh copies it into each app. Edit it there, never in an app.
//
// Once a day the app asks GitHub for its latest release. When that release is newer, a small window
// offers it. Update downloads the DMG, checks that the app inside is signed with our Developer ID
// and has the same bundle ID, swaps it in place, and relaunches. The request carries no data about
// the user: GitHub sees only that a copy of the app asked.
//
// Each app sets two Info.plist keys and adds one menu item:
//   TLSUpdateRepo   krishna-goutham-tls/lidawake
//   TLSUpdateAsset  LidAwake.dmg
//   menu.addItem(Updater.shared.menuItem); Updater.shared.start()
//
// Testing: `defaults write <bundle id> TLSUpdateFeed <url>` points the check at another JSON file
// (file:// works) in the shape of GitHub's releases/latest answer. Delete the key afterwards.

import AppKit
import Security
import SwiftUI

struct UpdateRelease: Equatable {
    let version: String
    let notes: String
    let download: URL
    let page: URL
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(text): return text }
    }
}

@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Only an app signed by this Apple team can replace the running app.
    nonisolated static let teamID = "859S7G7287"
    private static let interval: TimeInterval = 24 * 3_600
    private static let automaticKey = "TLSUpdateAutomatic"
    private static let lastCheckKey = "TLSUpdateLastCheck"
    private static let remindKey = "TLSUpdateRemindAfter"
    private static let feedKey = "TLSUpdateFeed"

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease)
        case installing(UpdateRelease)
        case failed(String, UpdateRelease?)
    }

    @Published private(set) var phase: Phase = .idle
    /// True while an automatic prompt is up. Then only a click starts the update, never Return.
    @Published private(set) var quiet = false
    /// Called before the app quits to relaunch as the new version.
    var willRelaunch: () -> Void = {}

    let appName: String
    let currentVersion: String
    private let repo: String?
    private let asset: String?
    private var timer: Timer?
    private var window: NSWindow?
    private var latest: UpdateRelease?

    lazy var menuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Check for updates…", action: #selector(menuClicked), keyEquivalent: "")
        item.target = self
        item.isHidden = !enabled
        return item
    }()

    var enabled: Bool { repo != nil && asset != nil }

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticKey)
            objectWillChange.send()
        }
    }

    private override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        appName = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "This app"
        currentVersion = info["CFBundleShortVersionString"] as? String ?? "0"
        repo = info["TLSUpdateRepo"] as? String
        asset = info["TLSUpdateAsset"] as? String
        super.init()
    }

    // MARK: Schedule

    /// Checks 30 s after launch if a day has passed, then looks again every hour.
    func start() {
        guard enabled, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.tick() }
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // A found update waits until someone is at the Mac to see it.
        if let latest, case .available = phase, !Self.screenLocked(), remindDue {
            show(.available(latest), takeFocus: false)
            return
        }
        guard automatic, !isBusy else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        Task { await check(manual: false) }
    }

    private var remindDue: Bool {
        let after = UserDefaults.standard.object(forKey: Self.remindKey) as? Date ?? .distantPast
        return Date() >= after
    }

    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: Check

    @objc private func menuClicked() {
        if let latest, case .available = phase {
            show(.available(latest))
        } else {
            Task { await check(manual: true) }
        }
    }

    func check(manual: Bool) async {
        guard enabled, !isBusy else { return }
        phase = .checking
        if manual { show(.checking) }
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if Self.isNewer(release.version, than: currentVersion) {
                latest = release
                phase = .available(release)
                if manual {
                    show(.available(release))
                } else if remindDue && !Self.screenLocked() {
                    show(.available(release), takeFocus: false)
                }
            } else {
                latest = nil
                phase = .upToDate
                if manual { show(.upToDate) } else { phase = .idle }
            }
        } catch {
            phase = manual ? .failed("Could not check for updates. \(error.localizedDescription)", nil) : .idle
            if manual { show(phase) }
        }
        refreshMenu()
    }

    private func fetchLatest() async throws -> UpdateRelease {
        let override = UserDefaults.standard.string(forKey: Self.feedKey).flatMap(URL.init(string:))
        guard let repo, let asset,
              let url = override ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.message("No update source is set.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(appName.replacingOccurrences(of: " ", with: ""))-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.message("GitHub answered \(http.statusCode).")
        }
        return try Self.parse(data, asset: asset)
    }

    nonisolated static func parse(_ data: Data, asset: String) throws -> UpdateRelease {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw UpdateError.message("The release information could not be read.")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let file = assets.first(where: { $0["name"] as? String == asset }),
              let link = file["browser_download_url"] as? String, let download = URL(string: link) else {
            throw UpdateError.message("The release has no \(asset).")
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? download
        return UpdateRelease(version: version, notes: json["body"] as? String ?? "", download: download, page: page)
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let left = parts(candidate), right = parts(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Install

    func later() {
        UserDefaults.standard.set(Date().addingTimeInterval(Self.interval), forKey: Self.remindKey)
        closeWindow()
    }

    func install() {
        guard let release = latest else { return }
        phase = .downloading(release)
        refreshMenu()
        Task {
            do {
                let target = Bundle.main.bundleURL
                let fallback = try await Self.downloadAndInstall(release, replacing: target, bundleID: Bundle.main.bundleIdentifier ?? "")
                if let dmg = fallback {
                    // The app folder is not writable, so the person drags the new copy in.
                    NSWorkspace.shared.open(dmg)
                    phase = .failed("Drag \(appName) to Applications in the window that opened, then open it again.", release)
                    show(phase)
                    return
                }
                phase = .installing(release)
                relaunch(at: target)
            } catch {
                phase = .failed("The update did not install. \(error.localizedDescription)", release)
                show(phase)
            }
            refreshMenu()
        }
    }

    /// Downloads, checks and swaps the app. Returns the DMG instead when the app cannot be replaced
    /// in place. Runs the slow steps off the main thread.
    nonisolated static func downloadAndInstall(_ release: UpdateRelease, replacing target: URL, bundleID: String) async throws -> URL? {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("tls-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent(release.download.lastPathComponent)
        if release.download.isFileURL {
            try FileManager.default.copyItem(at: release.download, to: dmg)
        } else {
            let (file, response) = try await URLSession.shared.download(from: release.download)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.message("The download failed (\(http.statusCode)).")
            }
            try FileManager.default.moveItem(at: file, to: dmg)
        }

        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path])
        guard attach.status == 0 else { throw UpdateError.message("The disk image did not open.") }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }

        let items = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == bundleID }) else {
            throw UpdateError.message("The disk image does not hold this app.")
        }
        guard let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              version == release.version else {
            throw UpdateError.message("The app in the disk image is not version \(release.version).")
        }
        try verifySignature(app, bundleID: bundleID)

        let folder = target.deletingLastPathComponent()
        let translocated = target.path.contains("/AppTranslocation/")
        guard !translocated, FileManager.default.isWritableFile(atPath: folder.path) else {
            // Keep the DMG where Finder can open it after this function's temp work is gone.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(dmg.lastPathComponent)
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: dmg, to: kept)
            try? FileManager.default.removeItem(at: work)
            return kept
        }

        let staged = folder.appendingPathComponent(".\(target.lastPathComponent).update")
        try? FileManager.default.removeItem(at: staged)
        let copy = run("/usr/bin/ditto", [app.path, staged.path])
        guard copy.status == 0 else { throw UpdateError.message("The new copy could not be written.") }
        try verifySignature(staged, bundleID: bundleID)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { try? FileManager.default.removeItem(at: work) }
        return nil
    }

    /// Developer ID from our team, the same bundle ID, and every nested file intact.
    nonisolated static func verifySignature(_ app: URL, bundleID: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.message("The new app could not be read.")
        }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(bundleID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.message("The signature check could not start.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError.message("The new app is not signed by thelaunch.space.")
        }
    }

    private func relaunch(at app: URL) {
        willRelaunch()
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func screenLocked() -> Bool {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        return info?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: Menu and window

    private func refreshMenu() {
        switch phase {
        case let .available(release), let .failed(_, release?):
            menuItem.title = "Update to \(release.version)…"
        case .downloading, .installing:
            menuItem.title = "Updating…"
        default:
            menuItem.title = "Check for updates…"
        }
    }

    /// An automatic prompt never takes the keyboard: someone typing in another app could press
    /// Return and start an update without reading it. It appears in front and waits for a click.
    private func show(_ phase: Phase, takeFocus: Bool = true) {
        self.phase = phase
        quiet = !takeFocus
        refreshMenu()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = NSHostingView(rootView: UpdateView(updater: self))
            self.window = window
        }
        guard let window else { return }
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 420, height: 200))
        if !window.isVisible { window.center() }
        if takeFocus {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func closeWindow() {
        window?.orderOut(nil)
        if case .upToDate = phase { phase = .idle }
        if case .failed(_, nil) = phase { phase = .idle }
        if case let .failed(_, release?) = phase { phase = .available(release) }
        refreshMenu()
    }

    func openPage() {
        if let latest { NSWorkspace.shared.open(latest.page) }
    }

    /// Draws one state of the window to a PNG, for design review. Touches no settings.
    static func snapshot(_ phase: Phase, dark: Bool, to path: String) {
        let updater = Updater.shared
        updater.phase = phase
        let host = NSHostingView(rootView: UpdateView(updater: updater).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `--update-test <feed url> <app to replace> <pretend version>`: the check, download, signature
    /// check and swap, without the window or a relaunch. Prints what happened.
    nonisolated static func commandLineTest(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: "--update-test"), arguments.count > index + 3,
              let feed = URL(string: arguments[index + 1]) else { return nil }
        let target = URL(fileURLWithPath: arguments[index + 2])
        let pretend = arguments[index + 3]
        let asset = Bundle.main.infoDictionary?["TLSUpdateAsset"] as? String ?? ""
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 1
        Task.detached {
            do {
                let data = feed.isFileURL ? try Data(contentsOf: feed) : try await URLSession.shared.data(from: feed).0
                let release = try parse(data, asset: asset)
                print("latest: \(release.version), this copy pretends to be \(pretend)")
                guard isNewer(release.version, than: pretend) else {
                    print("up to date")
                    status = 0
                    semaphore.signal()
                    return
                }
                let fallback = try await downloadAndInstall(release, replacing: target, bundleID: bundleID)
                if let fallback {
                    print("folder not writable, would open \(fallback.path)")
                } else {
                    let now = Bundle(url: target)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    print("installed: \(target.path) is now \(now)")
                }
                status = 0
            } catch {
                print("error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        return status
    }
}

// MARK: Window view

private struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(failure ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    if let notes, !notes.isEmpty {
                        ScrollView {
                            Text(notes)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 110)
                        .padding(.top, 8)
                    }
                }
            }

            HStack(spacing: 8) {
                Toggle("Check daily", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                buttons
            }
            .controlSize(.large)
            .padding(.top, 18)
        }
        .padding(EdgeInsets(top: 30, leading: 22, bottom: 18, trailing: 22))
        .frame(width: 420)
    }

    private var failure: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var title: String {
        switch updater.phase {
        case let .available(release), let .downloading(release), let .installing(release):
            return "\(updater.appName) \(release.version) is ready"
        case .upToDate: return "\(updater.appName) is up to date"
        case .checking, .idle: return "Checking for updates…"
        case .failed: return "Update not finished"
        }
    }

    private var detail: String {
        switch updater.phase {
        case .available: return "You have \(updater.currentVersion). It takes a few seconds and reopens by itself."
        case .downloading: return "Downloading…"
        case .installing: return "Installing. \(updater.appName) reopens in a moment."
        case .upToDate: return "You have \(updater.currentVersion), the newest version."
        case .checking, .idle: return "Asking GitHub for the newest version."
        case let .failed(message, _): return message
        }
    }

    private var notes: String? {
        guard case let .available(release) = updater.phase else { return nil }
        let lines = release.notes
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("#") ? String($0.drop { $0 == "#" || $0 == " " }) : $0 }
        return lines.prefix(12).joined(separator: "\n")
    }

    @ViewBuilder private var buttons: some View {
        switch updater.phase {
        case .available:
            Button("Later") { updater.later() }
                .keyboardShortcut(.cancelAction)
            if updater.quiet {
                Button("Update") { updater.install() }
                    .buttonStyle(UpdatePrimaryStyle())
            } else {
                Button("Update") { updater.install() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(UpdatePrimaryStyle())
            }
        case .downloading, .installing, .checking, .idle:
            ProgressView().controlSize(.small)
        case let .failed(_, release):
            if release != nil {
                Button("Download page") { updater.openPage() }
            }
            Button("Close") { updater.closeWindow() }
                .keyboardShortcut(.defaultAction)
        case .upToDate:
            Button("OK") { updater.closeWindow() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(UpdatePrimaryStyle())
        }
    }
}

/// A solid accent capsule. The native prominent style turns grey whenever the window is not key,
/// and an automatic prompt is never key.
private struct UpdatePrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Capsule().fill(Color.accentColor))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
