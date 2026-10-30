import AppKit

/// Borderless panels refuse keyboard focus unless told otherwise.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The search box: a text field, a result list and a footer with the search time.
final class SearchPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let engine: Engine
    var index: FileIndex { engine.files }
    var indexing = true

    private let panel: KeyPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var results: [ResultRow] = []
    private var thumbCache: [String: NSImage] = [:]
    private var userMoved = false
    private var lastMs = 0.0
    private var iconCache: [String: NSImage] = [:]

    private let width: CGFloat = 720
    private let fieldH: CGFloat = 58
    private let rowH: CGFloat = 50
    private let imageRowH: CGFloat = 84
    private let maxListH: CGFloat = 470
    private let footerH: CGFloat = 28

    init(engine: Engine) {
        self.engine = engine
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 58),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        panel.contentView = bg

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        glass.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.placeholderString = "Search by name, by words, or by what you remember"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowH
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        footer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        for v in [glass, field, line, scroll, footer] { bg.addSubview(v) }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            glass.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: fieldH / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            line.topAnchor.constraint(equalTo: bg.topAnchor, constant: fieldH),
            line.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -7),
        ])
    }

    // MARK: Show and hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        resize()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let top = f.maxY - f.height * 0.22
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - width / 2, y: top))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        engine.indexer?.hold(true)
        updateFooter()
    }

    func type(_ text: String) { field.stringValue = text; runSearch() }

    /// Fills the panel without showing it, for checks while someone uses the Mac.
    func render(_ text: String, done: @escaping () -> Void) {
        field.stringValue = text
        let t0 = DispatchTime.now().uptimeNanoseconds
        engine.search(text) { [weak self] rows, final in
            self?.draw(rows, t0)
            if final { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done) }
        }
    }

    /// Draws the panel into a PNG. Works without a screen, for checks and demos.
    func snapshot(to path: String) {
        guard let v = panel.contentView else { return }
        v.layoutSubtreeIfNeeded()
        (v as? NSVisualEffectView)?.material = .windowBackground
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func engineReady() { if isVisible { engine.indexer?.hold(true) } }

    func hide() {
        engine.indexer?.hold(false)
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    func windowDidResignKey(_ notification: Notification) { if panel.isVisible { hide() } }

    private func resize() {
        let rows = results.count
        let listH = rows > 0 ? min(maxListH, results.reduce(8) { $0 + height($1) }) : 0
        let h = fieldH + listH + (field.stringValue.isEmpty ? 0 : footerH)
        var f = panel.frame
        let top = f.maxY
        f.size = NSSize(width: width, height: h)
        f.origin.y = top - h
        panel.setFrame(f, display: true)
        scroll.isHidden = rows == 0
        footer.isHidden = field.stringValue.isEmpty
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { runSearch() }

    func runSearch() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        let t0 = DispatchTime.now().uptimeNanoseconds
        userMoved = false
        if q.isEmpty { draw([], t0); return }
        engine.search(q) { [weak self] rows, _ in self?.draw(rows, t0) }
    }

    private func draw(_ rows: [ResultRow], _ t0: UInt64) {
        let keep = userMoved ? selectedPath : nil
        results = rows
        lastMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        table.reloadData()
        if !results.isEmpty {
            let r = keep.flatMap { p in results.firstIndex { $0.path == p } } ?? 0
            table.selectRowIndexes([r], byExtendingSelection: false)
            table.scrollRowToVisible(r)
        }
        resize()
        updateFooter()
    }

    private func height(_ r: ResultRow) -> CGFloat { r.isImage ? imageRowH : rowH }

    func updateFooter() {
        let n = NumberFormatter.localizedString(from: NSNumber(value: index.liveCount), number: .decimal)
        var status = indexing ? "reading your files… \(n) so far" : "\(n) files"
        if let idx = engine.indexer, idx.isActive { status = idx.status }
        let found = results.isEmpty ? "no matches" : "\(results.count == 30 ? "30+" : "\(results.count)") results"
        footer.stringValue = String(format: "%@ in %.2f ms   ·   %@   ·   ↩ open   ⌘↩ show in Finder", found, lastMs, status)
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true { revealSelected() } else { openSelected() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; runSearch() }
            return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        let r = max(0, min(results.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
        userMoved = true
    }

    private var selectedPath: String? {
        let r = table.selectedRow
        return r >= 0 && r < results.count ? results[r].path : nil
    }

    @objc func openSelected() {
        guard let p = selectedPath else { return }
        hide()
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    func revealSelected() {
        guard let p = selectedPath else { return }
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(results[row]) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell) ?? ResultCell()
        let r = results[row]
        var dir = (r.path as NSString).deletingLastPathComponent
        if dir.hasPrefix(index.home) { dir = "~" + dir.dropFirst(index.home.count) }
        let name = (r.path as NSString).lastPathComponent
        let snip = engine.snippet(for: r)
        if snip != nil || r.isImage {
            let t = NSMutableAttributedString(string: name, attributes: [.font: cell.title.font!, .foregroundColor: NSColor.labelColor])
            if snip != nil {
                t.append(NSAttributedString(string: "   " + dir, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            cell.title.attributedStringValue = t
        } else {
            cell.title.stringValue = name
        }
        cell.subtitle.stringValue = snip ?? dir
        cell.subtitle.lineBreakMode = snip == nil ? .byTruncatingHead : .byTruncatingTail
        let thumb = r.isImage ? thumbnail(r.path) : nil
        cell.icon.image = thumb ?? icon(r.path)
        cell.setIconSize(r.isImage && thumb != nil ? 70 : 30)
        return cell
    }

    private func thumbnail(_ p: String) -> NSImage? {
        if let i = thumbCache[p] { return i }
        guard let d = engine.thumbnail(path: p), let i = NSImage(data: d) else { return nil }
        if thumbCache.count > 500 { thumbCache.removeAll() }
        thumbCache[p] = i
        return i
    }

    private func icon(_ p: String) -> NSImage {
        if let i = iconCache[p] { return i }
        let i = NSWorkspace.shared.icon(forFile: p)
        if iconCache.count > 2000 { iconCache.removeAll() }
        iconCache[p] = i
        return i
    }
}

final class ResultCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("result")
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    private var iconW: NSLayoutConstraint!
    private var iconH: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 6
        icon.layer?.masksToBounds = true
        for v in [icon, title, subtitle] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        iconW = icon.widthAnchor.constraint(equalToConstant: 30)
        iconH = icon.heightAnchor.constraint(equalToConstant: 30)
        let block = NSLayoutGuide()
        addLayoutGuide(block)
        NSLayoutConstraint.activate([
            iconW, iconH,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: block.topAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.bottomAnchor.constraint(equalTo: block.bottomAnchor),
            block.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setIconSize(_ s: CGFloat) { iconW.constant = s; iconH.constant = s }

    required init?(coder: NSCoder) { fatalError() }
}
