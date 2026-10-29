import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let index = FileIndex()
    private var panel: SearchPanel!
    private var hotKey: HotKey?
    private var watcher: Watcher?
    private var statusItem: NSStatusItem!
    private let countItem = NSMenuItem(title: "Reading your files…", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SearchPanel(index: index)
        hotKey = HotKey { [weak self] in self?.panel.toggle() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "mac-search")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Search  (⌥ Space)", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(countItem)
        menu.addItem(NSMenuItem(title: "Read all files again", action: #selector(rebuild), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit mac-search", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for i in menu.items { i.target = i.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        statusItem.menu = menu

        rebuild()
        watcher = Watcher(roots: [index.home, "/Applications"]) { [weak self] paths in
            guard let self else { return }
            for p in paths { self.index.update(path: p) }
            self.refreshCount()
            if self.panel.isVisible { self.panel.runSearch() }
        }
        if hotKey?.isRegistered != true {
            countItem.title = "Option+Space is taken by another app"
        }
    }

    @objc func showPanel() { panel.show() }

    @objc func rebuild() {
        panel.indexing = true
        let home = index.home
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = FileIndex.walk(home: home)
            DispatchQueue.main.async {
                self.index.load(entries)
                self.panel.indexing = false
                self.refreshCount(seconds: Date().timeIntervalSince(t0))
                if self.panel.isVisible { self.panel.runSearch() }
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

    private var lastWalk = 0.0
    private func refreshCount(seconds: Double? = nil) {
        if let seconds { lastWalk = seconds }
        let n = NumberFormatter.localizedString(from: NSNumber(value: index.liveCount), number: .decimal)
        countItem.title = String(format: "%@ files, read in %.1f s", n, lastWalk)
        panel.updateFooter()
    }
}
