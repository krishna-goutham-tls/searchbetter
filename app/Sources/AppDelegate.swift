import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let root: String?
    private let engine: Engine
    private var index: FileIndex { engine.files }
    private var panel: SearchPanel!
    private var hotKey: HotKey?
    private var watcher: Watcher?
    private var statusItem: NSStatusItem!
    private let hotKeyWarning = NSMenuItem(title: "Option+Space is taken by another app", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let meaningItem = NSMenuItem(title: "Start indexing file contents", action: #selector(toggleMeaning), keyEquivalent: "")

    private static let enabledKey = "meaning.enabled"

    init(root: String?) {
        self.root = root
        engine = Engine(root: root)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Guardian.start(root: root)
        panel = SearchPanel(engine: engine)
        hotKey = HotKey { [weak self] in self?.panel.toggle() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "SearchBetter")
        let menu = NSMenu()
        func symbol(_ i: NSMenuItem, _ name: String) -> NSMenuItem {
            i.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            return i
        }
        menu.addItem(.sectionHeader(title: "SearchBetter"))
        let search = symbol(NSMenuItem(title: "Search", action: #selector(showPanel), keyEquivalent: " "), "magnifyingglass")
        search.keyEquivalentModifierMask = .option
        menu.addItem(search)
        menu.addItem(hotKeyWarning)
        hotKeyWarning.isHidden = true
        menu.addItem(statusLine)
        statusLine.isHidden = true
        menu.addItem(meaningItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SearchBetter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for i in menu.items { i.target = i.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        statusItem.menu = menu

        // Opening the app by hand shows something at once. A restart after a crash stays quiet.
        if root == nil && !CommandLine.arguments.contains("--restarted") { panel.show() }

        rebuild()
        watcher = Watcher(roots: index.includeApps ? [index.home, "/Applications"] : [index.home]) { [weak self] paths in
            guard let self else { return }
            for p in paths {
                self.index.update(path: p)
                if !self.index.isSkipped(p) { self.engine.indexer?.touch(p) }
            }
            self.refreshCount()
            if self.panel.isVisible { self.panel.refreshResults() }
        }
        if hotKey?.isRegistered != true {
            hotKeyWarning.isHidden = false
        }
    }

    @objc func showPanel() { panel.show() }

    @objc func rebuild() {
        panel.indexing = true
        let home = index.home, apps = index.includeApps
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = FileIndex.walk(home: home, includeApps: apps)
            DispatchQueue.main.async {
                self.index.load(entries)
                self.panel.indexing = false
                self.refreshCount()
                if self.engine.meaningEnabled { self.engine.indexer?.start(paths: self.index.paths) }
                else if self.root != nil || UserDefaults.standard.bool(forKey: Self.enabledKey) { self.startMeaning() }
                if self.panel.isVisible { self.panel.refreshResults() }
                // `--show <query>` opens the panel with a query typed in, for screenshots and demos.
                let a = CommandLine.arguments
                if let i = a.firstIndex(of: "--show") {
                    self.panel.show()
                    if i + 1 < a.count { self.panel.type(a[i + 1]) }
                    if let j = a.firstIndex(of: "--snapshot"), j + 1 < a.count {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.panel.snapshot(to: a[j + 1]) }
                    }
                }
            }
        }
    }

    /// Opening the app from Applications or Spotlight while it runs brings up the search box.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { Guardian.cleanExit(); engine.shutdown() }

    // MARK: Meaning index

    /// Indexing starts only when asked: the first pass on a full Mac takes hours.
    private func startMeaning() {
        guard !engine.meaningEnabled else { return }
        meaningItem.title = "Loading the index…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard engine.openMeaning() else {
                DispatchQueue.main.async { self.meaningItem.title = "Model or llama-server not found" }
                return
            }
            DispatchQueue.main.async { [self] in
                engine.indexer?.onProgress = { [weak self] in
                    DispatchQueue.main.async { self?.refreshMeaning() }
                }
                panel.engineReady()
                engine.indexer?.start(paths: index.paths)
                refreshMeaning()
            }
        }
    }

    @objc func toggleMeaning() {
        guard let idx = engine.indexer else {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            startMeaning()
            return
        }
        idx.setPaused(!idx.isPaused)
        refreshMeaning()
    }

    private var lastMeaningRefresh = Date.distantPast
    private func refreshMeaning() {
        guard let idx = engine.indexer else { return }
        // Quiet once every file is searchable: the menu shows progress only while there is something to wait for.
        statusLine.isHidden = !idx.showsProgress
        statusLine.title = idx.status
        meaningItem.title = idx.isPaused ? "Resume Indexing" : "Pause Indexing"
        meaningItem.isHidden = !idx.showsProgress
        if Date().timeIntervalSince(lastMeaningRefresh) > 0.5 { lastMeaningRefresh = Date(); panel.updateFooter() }
    }

    private func refreshCount() {
        panel.updateFooter()
    }
}
