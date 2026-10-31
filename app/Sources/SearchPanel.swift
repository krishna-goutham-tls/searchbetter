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
    private let line = NSBox()
    private let content = NSView()
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
    private let corner: CGFloat = 26     // close to a macOS 26 window
    private var margin: CGFloat = 0
    private var glassView: NSView?
    private let softShadow = CALayer()
    private let shadowHole = CAShapeLayer()

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

        // Liquid Glass on macOS 26. Older systems get Apple's plain blur.
        let bg = content
        bg.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            // The glass draws its own edge light and shadow past its bounds. They need clear window around them,
            // or the window's square corners show.
            margin = 44
            panel.hasShadow = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: width + margin * 2, height: fieldH + margin * 2))
            root.autoresizingMask = [.width, .height]
            root.wantsLayer = true
            // The window shadow would follow the square window, so a soft shadow is drawn around the glass only.
            softShadow.shadowColor = NSColor.black.cgColor
            softShadow.shadowOpacity = 0.28
            softShadow.shadowRadius = 22
            softShadow.shadowOffset = CGSize(width: 0, height: -10)
            softShadow.mask = shadowHole
            shadowHole.fillRule = .evenOdd
            root.layer?.addSublayer(softShadow)
            let g = NSGlassEffectView(frame: root.bounds.insetBy(dx: margin, dy: margin))
            g.style = .regular
            g.cornerRadius = corner
            g.contentView = bg
            root.addSubview(g)
            glassView = g
            panel.contentView = root
        } else {
            let v = NSVisualEffectView()
            v.material = .popover
            v.state = .active
            v.blendingMode = .behindWindow
            v.wantsLayer = true
            v.layer?.cornerRadius = corner
            v.layer?.masksToBounds = true
            v.autoresizingMask = [.width, .height]
            bg.frame = v.bounds
            v.addSubview(bg)
            panel.contentView = v
        }

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        glass.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = "SearchBetter  ·  type what you remember"
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
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        footer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        for v in [glass, field, line, scroll, footer] { bg.addSubview(v) }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            glass.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: fieldH / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            line.topAnchor.constraint(equalTo: bg.topAnchor, constant: fieldH),
            line.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
        ])
        // Low priority: the empty panel is shorter than the list and footer need, and must not grow to fit them.
        let bottom = footer.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -7)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    // MARK: Show and hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        resize()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let top = f.maxY - f.height * 0.22
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - width / 2 - margin, y: top + margin))
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

    /// Off-screen check: Down reaches the last row, and a change on disk does not move the selection.
    func arrowsReachEnd() -> Bool {
        for _ in results { move(1) }
        let end = table.selectedRow
        refreshResults()
        return end == results.count - 1 && table.selectedRow == end
    }

    /// Shows the real glass for a moment over a test backdrop, without taking the keyboard, and saves that area
    /// to a PNG. Only the backdrop and the panel are in the picture, never what is on the screen.
    func capture(to path: String) {
        guard let screen = NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.minX + 40, y: f.minY + 40))
        let area = panel.frame.insetBy(dx: -20, dy: -20)
        let back = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        back.isReleasedWhenClosed = false
        back.level = .modalPanel
        let tile = NSImage(size: area.size, flipped: false) { r in
            switch ProcessInfo.processInfo.environment["BACKDROP"] {
            case "dark": NSColor(white: 0.12, alpha: 1).setFill(); r.fill()
            case "light": NSColor(white: 0.96, alpha: 1).setFill(); r.fill()
            default: NSGradient(colors: [.white, .systemTeal, .black, .systemOrange])?.draw(in: r, angle: 20)
            }
            return true
        }
        back.contentView = NSImageView(image: tile)
        back.orderFrontRegardless()
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let y = screen.frame.maxY - area.maxY
            p.arguments = ["-x", "-R", "\(Int(area.minX)),\(Int(y)),\(Int(area.width)),\(Int(area.height))", path]
            try? p.run()
            p.waitUntilExit()
            panel.orderOut(nil)
            back.orderOut(nil)
            print("panel \(panel.frame.size)")
        }
    }

    /// Draws the panel into a PNG. Works without a screen, for checks and demos.
    func snapshot(to path: String) {
        // The glass cannot draw off screen, because it samples what sits behind the window. This shows the contents.
        let v = content
        panel.contentView?.layoutSubtreeIfNeeded()
        v.layoutSubtreeIfNeeded()
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

    private func updateShadow(width w: CGFloat, height h: CGFloat) {
        guard margin > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let all = CGRect(x: 0, y: 0, width: w + margin * 2, height: h + margin * 2)
        // Set directly: autoresizing distorts the glass when the window starts smaller than its margins need.
        glassView?.frame = all.insetBy(dx: margin, dy: margin)
        let shape = CGPath(roundedRect: all.insetBy(dx: margin, dy: margin), cornerWidth: corner, cornerHeight: corner, transform: nil)
        softShadow.frame = all
        softShadow.shadowPath = shape
        shadowHole.frame = all
        let hole = CGMutablePath()
        hole.addRect(all)
        hole.addPath(shape)
        shadowHole.path = hole   // the shadow must not show through the glass
        CATransaction.commit()
    }

    private func resize() {
        let rows = results.count
        let listH = rows > 0 ? min(maxListH, results.reduce(8) { $0 + height($1) }) : 0
        let h = fieldH + listH + (field.stringValue.isEmpty ? 0 : footerH)
        var f = panel.frame
        let top = f.maxY
        f.size = NSSize(width: width + margin * 2, height: h + margin * 2)
        f.origin.y = top - h
        panel.setFrame(f, display: true)
        updateShadow(width: width, height: h)
        scroll.isHidden = rows == 0
        line.isHidden = rows == 0
        footer.isHidden = field.stringValue.isEmpty
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { runSearch() }

    /// Files changed on disk. The list stays still once the user moves through it, so the selection cannot jump.
    func refreshResults() { if !userMoved { runSearch() } }

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
        let found = results.isEmpty ? "no matches" : results.count == 1 ? "1 result" : "\(results.count) results"
        footer.stringValue = String(format: "%@ in %.0f ms   ·   %@   ·   ↩ open   ⌘↩ show in Finder", found, lastMs, status)
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GlassRow() }

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
        guard let d = engine.thumbnail(path: p), let src = NSImage(data: d), src.size.width > 0, src.size.height > 0 else { return nil }
        // Round the picture itself. Rounding its view leaves sharp corners when the picture does not fill the view.
        let scale = 70 / max(src.size.width, src.size.height)
        let i = NSImage(size: src.size, flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: 10 / scale, yRadius: 10 / scale).addClip()
            src.draw(in: r)
            return true
        }
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

/// A soft rounded selection that sits on the glass, in place of the system's solid bar.
final class GlassRow: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 14, yRadius: 14).fill()
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
