import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let deadlineItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let dailyItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let deadlineMenu = NSMenu()
    private let dailyMenu = NSMenu()

    private var deadlines: [Deadline] = []
    private var daily: Daily?
    private var deadlineFailed = false
    private var dailyFailed = false
    private var deadlineLoaded = false
    private var dailyLoaded = false
    private var deadlinePrefix: String { Settings.showLabels ? "Due" : "" }
    private var dailyPrefix: String { Settings.showLabels ? "Day" : "" }
    private var timer: Timer?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        for (menu, item) in [(deadlineMenu, deadlineItem), (dailyMenu, dailyItem)] {
            menu.delegate = self
            item.menu = menu
        }
        render()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if !Settings.showDeadline && !Settings.showDaily { openSettings() }
    }

    /// With both bars hidden there is no menu to reach Settings from, so opening the app again shows it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Settings.showDeadline && !Settings.showDaily { openSettings() }
        return false
    }

    // MARK: Data

    private var selectedDeadline: Deadline? {
        if let id = Settings.selectedDeadlineID, let match = deadlines.first(where: { $0.id == id }) {
            return match
        }
        return deadlines.min { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    @objc private func refresh() {
        guard Settings.token != nil, !Settings.dataSourceID.isEmpty || !Settings.dailyPageID.isEmpty else {
            render()
            return
        }
        if !Settings.dataSourceID.isEmpty { Task { @MainActor in
            do {
                deadlines = try await Notion.fetchDeadlines()
                deadlineFailed = false
                deadlineLoaded = true
            } catch { deadlineFailed = true }
            render()
        } }
        if !Settings.dailyPageID.isEmpty { Task { @MainActor in
            do {
                daily = try await Notion.fetchDaily()
                dailyFailed = false
                dailyLoaded = true
            } catch { dailyFailed = true }
            render()
        } }
    }

    // MARK: Rendering

    private func render() {
        deadlineItem.isVisible = Settings.showDeadline
        dailyItem.isVisible = Settings.showDaily
        guard Settings.token != nil else {
            setPlain(deadlineItem, "⏳ set token")
            setPlain(dailyItem, "⏳ set token")
            return
        }
        let warn = "⚠︎"
        if Settings.stackBars, Settings.showDeadline, Settings.showDaily, let a = selectedDeadline, let b = daily {
            let deadlineBar = (deadlineFailed ? "⚠︎" : "") + BarRenderer.label(timeLeft: a.timeLeft, percent: a.percent)
            let dailyBar = (dailyFailed ? "⚠︎" : "") + BarRenderer.label(timeLeft: b.timeLeft, percent: b.percent)
            let dl = BarRow(text: deadlineBar, percent: a.percent, colors: Settings.deadlineColors, prefix: deadlinePrefix)
            let wd = BarRow(text: dailyBar, percent: b.percent, colors: Settings.dailyColors, prefix: dailyPrefix)
            showBars(deadlineItem, rows: Settings.dailyOnTop ? [wd, dl] : [dl, wd])
            dailyItem.isVisible = false
            return
        }
        if let d = selectedDeadline {
            var text = BarRenderer.label(timeLeft: d.timeLeft, percent: d.percent)
            if deadlineFailed { text = warn + text }
            set(deadlineItem, text: text, percent: d.percent, colors: Settings.deadlineColors, prefix: deadlinePrefix)
        } else if Settings.dataSourceID.isEmpty {
            setPlain(deadlineItem, "⏳ set database")
        } else {
            setPlain(deadlineItem, deadlineFailed ? "⏳ \(warn)" : (deadlineLoaded ? "⏳ none" : "⏳ …"))
        }
        if let d = daily {
            var text = BarRenderer.label(timeLeft: d.timeLeft, percent: d.percent)
            if dailyFailed { text = warn + text }
            set(dailyItem, text: text, percent: d.percent, colors: Settings.dailyColors, prefix: dailyPrefix)
        } else if Settings.dailyPageID.isEmpty {
            setPlain(dailyItem, "⏳ set workday")
        } else {
            setPlain(dailyItem, dailyFailed ? "⏳ \(warn)" : "⏳ …")
        }
    }

    private func set(_ item: NSStatusItem, text: String, percent: Double, colors: BarColors, prefix: String) {
        showBars(item, rows: [BarRow(text: text, percent: percent, colors: colors, prefix: prefix)])
    }

    private var glassViews: [ObjectIdentifier: GlassBarsView] = [:]

    private func showBars(_ item: NSStatusItem, rows: [BarRow]) {
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        let key = ObjectIdentifier(item)
        let view = glassViews[key] ?? GlassBarsView()
        if glassViews[key] == nil {
            glassViews[key] = view
            button.addSubview(view)
        }
        view.isHidden = false
        view.update(rows: rows)
        item.length = view.contentWidth
        view.setFrameOrigin(NSPoint(x: 0, y: (button.bounds.height - 22) / 2))
    }

    private func hideGlass(_ item: NSStatusItem) {
        guard let view = glassViews[ObjectIdentifier(item)], !view.isHidden else { return }
        view.isHidden = true
        item.length = NSStatusItem.variableLength
    }

    private func setPlain(_ item: NSStatusItem, _ title: String) {
        hideGlass(item)
        item.button?.image = nil
        item.button?.title = title
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === deadlineMenu {
            let active = selectedDeadline?.id
            let sorted = deadlines.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            let font = NSFont.menuFont(ofSize: 0)
            let rows = sorted.map { ($0, BarRenderer.label(timeLeft: $0.timeLeft, percent: $0.percent)) }
            let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            func width(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }
            // Columns are indexed from the right so "%", "m", "h", "d", "y" line up even when rows omit years.
            let cells = rows.map { $0.1.split(separator: " ").reversed().map(String.init) }
            var columns: [CGFloat] = []
            for row in cells {
                for (i, cell) in row.enumerated() {
                    if i == columns.count { columns.append(0) }
                    columns[i] = max(columns[i], ceil(width(cell, digits)))
                }
            }
            let gap = ceil(width(" ", digits))
            let leftWidth = rows.map { width($0.0.label, font) }.max() ?? 0
            let rightWidth = columns.reduce(0, +) + gap * CGFloat(max(columns.count - 1, 0))
            let rowWidth = ceil(DeadlineRowView.leading + leftWidth + 24 + rightWidth + DeadlineRowView.trailing)
            for ((d, right), row) in zip(rows, cells) {
                let item = NSMenuItem(title: "\(d.label) - \(right)", action: #selector(pick(_:)), keyEquivalent: "")
                item.view = DeadlineRowView(left: d.label, cells: row, columns: columns, gap: gap, font: font,
                                            digits: digits, checked: d.id == active, width: rowWidth)
                item.target = self
                item.representedObject = d.id
                item.state = d.id == active ? .on : .off
                menu.addItem(item)
            }
            if sorted.isEmpty {
                let item = NSMenuItem(title: deadlineFailed ? "Could not load deadlines" : "No incomplete deadlines",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
            // A nil action greys the item out under the menu's default auto-enabling.
            let open = NSMenuItem(title: "Open in Notion",
                                  action: selectedDeadline == nil ? nil : #selector(openInNotion), keyEquivalent: "o")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
        }
        addCommonItems(to: menu)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func menuDidClose(_ menu: NSMenu) {}

    private func addCommonItems(to menu: NSMenu) {
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        let tokenItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        refreshItem.target = self
        tokenItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(tokenItem)
        menu.addItem(.separator())
        menu.addItem(quit)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        Settings.selectedDeadlineID = sender.representedObject as? String
        render()
    }

    @objc private func openInNotion() {
        guard let id = selectedDeadline?.id,
              let url = URL(string: "https://app.notion.com/p/" + id.replacingOccurrences(of: "-", with: "")) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController { [weak self] dataChanged in
                guard let self else { return }
                if dataChanged {
                    deadlines = []
                    daily = nil
                    deadlineLoaded = false
                    render()
                    refresh()
                } else {
                    render()
                }
            }
        }
        settingsWindow?.show()
    }

    /// Menu-bar-only apps have no main menu, so Cmd+C/V/X/A never reach text fields without one.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

/// NSMenu reserves a key-equivalent column that title text (even with a right tab stop) can't reach,
/// so deadline rows draw themselves to put the time left flush with the menu's trailing edge.
private final class DeadlineRowView: NSView {
    static let leading: CGFloat = 30
    static let trailing: CGFloat = 17
    private static let height: CGFloat = 24
    private static let highlightInset: CGFloat = 5

    private let left: String
    private let cells: [String]
    private let columns: [CGFloat]
    private let gap: CGFloat
    private let font: NSFont
    private let digits: NSFont
    private let checked: Bool

    /// `cells` and `columns` run right to left; each cell is right-aligned within its column's width.
    init(left: String, cells: [String], columns: [CGFloat], gap: CGFloat, font: NSFont, digits: NSFont,
         checked: Bool, width: CGFloat) {
        self.left = left
        self.cells = cells
        self.columns = columns
        self.gap = gap
        self.font = font
        self.digits = digits
        self.checked = checked
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            let rect = bounds.insetBy(dx: Self.highlightInset, dy: 0)
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textHeight = (left as NSString).size(withAttributes: attrs).height
        let y = (bounds.height - textHeight) / 2
        (left as NSString).draw(at: NSPoint(x: Self.leading, y: y), withAttributes: attrs)
        let digitAttrs: [NSAttributedString.Key: Any] = [.font: digits, .foregroundColor: color]
        var x = bounds.maxX - Self.trailing
        for (cell, column) in zip(cells, columns) {
            let w = (cell as NSString).size(withAttributes: digitAttrs).width
            (cell as NSString).draw(at: NSPoint(x: x - w, y: y), withAttributes: digitAttrs)
            x -= column + gap
        }

        if checked, let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")?
            .withSymbolConfiguration(.init(pointSize: font.pointSize - 1, weight: .semibold)
                .applying(.init(paletteColors: [color]))) {
            let origin = NSPoint(x: (Self.leading - check.size.width) / 2 + 2, y: (bounds.height - check.size.height) / 2)
            check.draw(in: NSRect(origin: origin, size: check.size))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        NSApp.sendAction(item.action!, to: item.target, from: item)
    }
}
