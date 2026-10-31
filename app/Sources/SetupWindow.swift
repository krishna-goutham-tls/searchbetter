import AppKit

/// The first-run window: one button, a progress bar, then "press Option+Space".
final class SetupWindow: NSObject {
    var onBegin: (() -> Void)?
    var onReady: (() -> Void)?
    var onTry: (() -> Void)?

    private enum Stage { case start, downloading(Int64), checking, failed(String), ready }

    private let hotKeyWorks: Bool
    private let headless: Bool
    private let window: NSWindow
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let barText = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let notes = NSStackView()
    private var stage = Stage.start
    private var download: ModelDownload?

    private static let width: CGFloat = 440

    init(hotKeyWorks: Bool, headless: Bool) {
        self.hotKeyWorks = hotKeyWorks
        self.headless = headless
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        build()
        apply(.start)
    }

    func show(begin: Bool) {
        if begin, case .start = stage { self.begin() }
        guard !headless else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let icon = NSImageView(image: NSImage(contentsOfFile: Bundle.main.bundlePath + "/Contents/Resources/AppIcon.icns") ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 96), icon.heightAnchor.constraint(equalToConstant: 96)])

        title.font = .systemFont(ofSize: 24, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(ModelDownload.size)
        barText.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        barText.textColor = .secondaryLabelColor

        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = 12

        button.target = self
        button.action = #selector(pressed)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [icon, title, subtitle, bar, barText, notes, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(22, after: barText)
        stack.setCustomSpacing(26, after: notes)
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 36, bottom: 30, right: 36)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        let inner = Self.width - 72
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
            subtitle.widthAnchor.constraint(equalToConstant: inner),
            bar.widthAnchor.constraint(equalToConstant: inner),
            notes.widthAnchor.constraint(equalToConstant: inner),
        ])
    }

    private func note(_ symbol: String, _ text: String) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [image, label])
        row.alignment = .top
        row.spacing = 10
        return row
    }

    private func setNotes(_ rows: [(String, String)]) {
        notes.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.forEach { notes.addArrangedSubview(note($0.0, $0.1)) }
        notes.isHidden = rows.isEmpty
    }

    private func apply(_ s: Stage) {
        stage = s
        let foldersNote = ("folder", "Your Mac will ask to open Desktop, Documents and Downloads. Click Allow each time.")
        let privateNote = ("lock", "Your files stay on this Mac. The model is the only download.")
        title.stringValue = "SearchBetter"
        bar.isHidden = true
        barText.isHidden = true
        button.isHidden = false
        switch s {
        case .start:
            subtitle.stringValue = "Find any file by typing what you remember."
            setNotes([("arrow.down.circle", "Downloads a 310 MB search model, one time."), foldersNote, privateNote])
            button.title = "Set Up"
        case .downloading(let n):
            subtitle.stringValue = "Downloading the search model"
            bar.isHidden = false
            barText.isHidden = false
            bar.doubleValue = Double(n)
            barText.stringValue = "\((n + 500_000) / 1_000_000) of \((ModelDownload.size + 500_000) / 1_000_000) MB"
            setNotes([foldersNote, privateNote])
            button.isHidden = true
        case .checking:
            subtitle.stringValue = "Getting the model ready"
            bar.isHidden = false
            barText.isHidden = true
            bar.doubleValue = bar.maxValue
            setNotes([foldersNote, privateNote])
            button.isHidden = true
        case .failed(let message):
            subtitle.stringValue = message
            setNotes([])
            button.title = "Try Again"
        case .ready:
            title.stringValue = "Ready"
            subtitle.stringValue = hotKeyWorks ? "Press Option + Space from anywhere to search." : "Click the magnifying glass in the menu bar to search."
            setNotes([("sparkle.magnifyingglass", "SearchBetter now reads your files in the background. It finds more as the reading goes on."),
                      ("powerplug", "Keep your Mac plugged in for the first read. It can take 15 minutes or more. Below 50% battery it waits for power.")])
            button.title = "Try It"
        }
        window.layoutIfNeeded()
        // Keep the top edge still when the window changes height.
        let h = window.contentView?.fittingSize.height ?? 400
        var f = window.frame
        f.origin.y += f.height - h
        f.size.height = h
        window.setFrame(f, display: true)
    }

    @objc private func pressed() {
        switch stage {
        case .start: onBegin?(); begin()
        case .failed: begin()
        case .ready: window.close(); onTry?()
        default: break
        }
    }

    private func begin() {
        if ModelFiles.available { check(); return }
        apply(.downloading(0))
        let d = ModelDownload()
        download = d
        d.onProgress = { [weak self] n in self?.apply(.downloading(n)) }
        d.onFinish = { [weak self] failure in
            guard let self else { return }
            self.download = nil
            switch failure {
            case .none: self.check()
            case .noSpace: self.fail("Your Mac needs 1 GB of free space. Free some space, then try again.")
            case .network: self.fail("The download stopped. Check your internet, then try again. It continues from where it stopped.")
            case .damaged: self.fail("The download was damaged. Try again.")
            }
        }
        d.start()
    }

    /// Starts the model once, so a problem shows here and not as a search that silently finds less.
    private func check() {
        apply(.checking)
        DispatchQueue.global(qos: .userInitiated).async {
            let server = EmbedServer(contextTokens: 512)
            let ok = server.start() && server.embed(texts: ["task: search result | query: test"]) != nil
            server.stop()
            DispatchQueue.main.async { [self] in
                if ok { apply(.ready); onReady?() }
                else { fail("The search model could not start on this Mac. Search by file name still works.") }
            }
        }
    }

    private func fail(_ message: String) {
        apply(.failed(message))
        if headless { print("setup failed: \(message)"); NSApp.terminate(nil) }
    }

    // MARK: Pictures for review

    static func render(stage: String, to out: String) -> Never {
        _ = NSApplication.shared
        let w = SetupWindow(hotKeyWorks: true, headless: true)
        switch stage {
        case "downloading": w.apply(.downloading(124_000_000))
        case "checking": w.apply(.checking)
        case "failed": w.apply(.failed("The download stopped. Check your internet, then try again. It continues from where it stopped."))
        case "ready": w.apply(.ready)
        default: w.apply(.start)
        }
        guard let v = w.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        exit(0)
    }
}
