import AppKit

/// Borderless panels refuse keyboard focus unless told otherwise.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The search box: a text field, a result list and a footer with the search time.
final class SearchPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let index: FileIndex
    var indexing = true

    private let panel: KeyPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var results: [FileIndex.Hit] = []
    private var lastMs = 0.0
    private var iconCache: [String: NSImage] = [:]

    private let width: CGFloat = 720
    private let fieldH: CGFloat = 58
    private let rowH: CGFloat = 46
    private let maxRows = 9
    private let footerH: CGFloat = 28

    init(index: FileIndex) {
        self.index = index
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
        field.placeholderString = "Search files, folders and apps"
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
        updateFooter()
    }

    func type(_ text: String) { field.stringValue = text; runSearch() }

    /// Draws the panel into a PNG. Works without a screen, for checks and demos.
    func snapshot(to path: String) {
        guard let v = panel.contentView else { return }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func hide() {
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    func windowDidResignKey(_ notification: Notification) { if panel.isVisible { hide() } }

    private func resize() {
        let rows = min(results.count, maxRows)
        let listH = rows > 0 ? CGFloat(rows) * rowH + 8 : 0
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
        results = q.isEmpty ? [] : index.search(q)
        lastMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        resize()
        updateFooter()
    }

    func updateFooter() {
        let n = NumberFormatter.localizedString(from: NSNumber(value: index.liveCount), number: .decimal)
        let status = indexing ? "reading your files… \(n) so far" : "\(n) files"
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
    }

    private var selectedPath: String? {
        let r = table.selectedRow
        return r >= 0 && r < results.count ? index.paths[results[r].id] : nil
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell) ?? ResultCell()
        let p = index.paths[results[row].id]
        cell.title.stringValue = (p as NSString).lastPathComponent
        var dir = (p as NSString).deletingLastPathComponent
        if dir.hasPrefix(index.home) { dir = "~" + dir.dropFirst(index.home.count) }
        cell.subtitle.stringValue = dir
        cell.icon.image = icon(p)
        return cell
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

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        for v in [icon, title, subtitle] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
