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
    private let meaningItem = NSMenuItem(title: "Finish Setup", action: #selector(toggleMeaning), keyEquivalent: "")
    private var setup: SetupWindow?
    private var servicesStarted = false
    private var walkDone = false
    private var meaningStarting = false
    private let autoSetup = CommandLine.arguments.contains("--setup-auto")

    private static let setupStartedKey = "setup.started"
    private var needsSetup: Bool { root == nil && !ModelFiles.available }

    init(root: String?) {
        self.root = root
        engine = Engine(root: root)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.runsFromDiskImage { Self.askToMove(); return }
        if !autoSetup { Guardian.start(root: root) }
        ModelFiles.clearHelperQuarantine()
        panel = SearchPanel(engine: engine)
        if !autoSetup { hotKey = HotKey { [weak self] in self?.panel.toggle() } }

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

        meaningItem.isHidden = !needsSetup
        if hotKey?.isRegistered != true { hotKeyWarning.isHidden = false }

        guard needsSetup else {
            // Opening the app by hand shows something at once. A restart after a crash stays quiet.
            if autoSetup { print("setup not needed"); NSApp.terminate(nil); return }
            if root == nil && !CommandLine.arguments.contains("--restarted") { panel.show() }
            startServices()
            return
        }
        // The folder prompts come with the first walk, so the walk waits for the Set Up click.
        let begin = autoSetup || UserDefaults.standard.bool(forKey: Self.setupStartedKey)
        if begin { startServices() }
        showSetup(begin: begin)
    }

    /// A copy that runs from the disk image or a random system folder loses its index link and its prompts.
    private static var runsFromDiskImage: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Volumes/") || p.contains("/AppTranslocation/")
    }

    private static func askToMove() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Move SearchBetter to Applications"
        a.informativeText = "Drag SearchBetter to the Applications folder. Then open it from there."
        a.addButton(withTitle: "Quit")
        a.runModal()
        NSApp.terminate(nil)
    }

    private func showSetup(begin: Bool) {
        if setup == nil {
            setup = SetupWindow(hotKeyWorks: hotKey?.isRegistered == true, headless: autoSetup)
            setup?.onBegin = { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: Self.setupStartedKey)
                self.startServices()
            }
            setup?.onReady = { [weak self] in
                guard let self else { return }
                self.meaningItem.isHidden = true
                if self.walkDone { self.startMeaning() }
                if self.autoSetup { print("setup ready"); DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) } }
            }
            setup?.onTry = { [weak self] in self?.setup = nil; self?.panel.show() }
        }
        setup?.show(begin: begin)
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
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
                self.walkDone = true
                self.refreshCount()
                if self.engine.meaningEnabled { self.engine.indexer?.start(paths: self.index.paths) }
                else if ModelFiles.available { self.startMeaning() }
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
        if needsSetup || setup != nil { showSetup(begin: false) } else { panel.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { Guardian.cleanExit(); engine.shutdown() }

    // MARK: Meaning index

    private func startMeaning() {
        guard !engine.meaningEnabled, !meaningStarting else { return }
        meaningStarting = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard engine.openMeaning() else {
                DispatchQueue.main.async { self.meaningStarting = false }
                return
            }
            DispatchQueue.main.async { [self] in
                meaningStarting = false
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
            if needsSetup { showSetup(begin: false) }
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
