import AppKit
import ServiceManagement

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate, NSTabViewDelegate {
    private let tokenField = NSSecureTextField()
    private let dataSourceField = NSTextField()
    private let pageField = NSTextField()
    private let formatField = NSTextField()
    private let stackCheckbox = NSButton(checkboxWithTitle: "Stack both bars in one menu-bar item", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let showDeadlineCheckbox = NSButton(checkboxWithTitle: "Show the Due (deadline) bar", target: nil, action: nil)
    private let showDailyCheckbox = NSButton(checkboxWithTitle: "Show the Day (workday) bar", target: nil, action: nil)
    private let hiddenHint = NSTextField(labelWithString: "Both bars hidden: open the app again to return here.")
    private let labelsCheckbox = NSButton(checkboxWithTitle: "Show Due/Day labels beside the bars", target: nil, action: nil)
    private let dailyTopCheckbox = NSButton(checkboxWithTitle: "When stacked, show the daily bar on top", target: nil, action: nil)
    /// Called after every change; `dataChanged` is true when the token, database or page changed.
    private var hintRow: NSGridRow?
    private let onChange: (_ dataChanged: Bool) -> Void
    private var debounce: Timer?
    private var colorsDebounce: Timer?

    private let tabView = NSTabView()
    private let generalStack = NSStackView()
    private let colorsStack = NSStackView()
    private let barSelector = NSSegmentedControl(labels: ["Deadline", "Daily"], trackingMode: .selectOne, target: nil, action: nil)
    private let preview = ColorPreviewView()
    private let rowsStack = ReorderableStackView()
    private let blendCheckbox = NSButton(checkboxWithTitle: "Blend between stops", target: nil, action: nil)
    private var wells: [ColorSwatchButton] = []
    private var pickingIndex = 0
    private let colorUndo = UndoManager()
    /// Identifies a run of live edits (dragging in the color panel, typing a percent) that undoes as one step.
    private var coalesceKey: String?
    private var percentFields: [NSTextField] = []
    private var editing = Settings.deadlineColors
    private var editingDaily = false

    init(onChange: @escaping (_ dataChanged: Bool) -> Void) {
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 295),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Deadline Progress Bars Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        tokenField.placeholderString = "Personal access token (stored in Keychain)"
        dataSourceField.placeholderString = "https://app.notion.com/p/…"
        pageField.placeholderString = "https://app.notion.com/p/…"
        formatField.placeholderString = BarRenderer.defaultFormat
        for field in [tokenField, dataSourceField, pageField, formatField] { field.delegate = self }
        for box in [showDeadlineCheckbox, showDailyCheckbox, stackCheckbox, labelsCheckbox, dailyTopCheckbox] {
            box.target = self
            box.action = #selector(applyNow)
        }
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)

        let hint = NSTextField(labelWithString: "{time} = time left, {percent} = progress")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        hiddenHint.font = .systemFont(ofSize: 11)
        hiddenHint.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Notion token:"), tokenField],
            [NSTextField(labelWithString: "Deadlines database URL:"), dataSourceField],
            [NSTextField(labelWithString: "Time left in workday URL:"), pageField],
            [NSTextField(labelWithString: "Label format:"), formatField],
            [NSView(), hint],
            [NSView(), loginCheckbox],
            [NSView(), showDeadlineCheckbox],
            [NSView(), showDailyCheckbox],
            [NSView(), hiddenHint],
            [NSView(), labelsCheckbox],
            [NSView(), stackCheckbox],
            [NSView(), dailyTopCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 280
        grid.rowSpacing = 10
        hintRow = grid.cell(for: hiddenHint)?.row
        addTab("General", content: grid, stack: generalStack)

        setUpColorsTab()
        tabView.delegate = self
        window.contentView = tabView
        resizeToFit()
    }

    private func addTab(_ title: String, content: NSView, stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(content)
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        let item = NSTabViewItem()
        item.label = title
        item.view = container
        tabView.addTabViewItem(item)
    }

    private func setUpColorsTab() {
        barSelector.target = self
        barSelector.action = #selector(barChanged)
        barSelector.selectedSegment = 0
        let barRow = NSStackView(views: [NSTextField(labelWithString: "Bar:"), barSelector])

        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 380),
            preview.heightAnchor.constraint(equalToConstant: ColorPreviewView.height),
        ])
        preview.onBegin = { [weak self] in self?.coalesceKey = nil }
        preview.onDrag = { [weak self] index, percent in self?.dragStop(index, to: percent) ?? percent }

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.onMove = { [weak self] from, to in self?.dropStop(from: from, gap: to) }

        let add = NSButton(title: "+ Add threshold", target: self, action: #selector(addStop))
        blendCheckbox.target = self
        blendCheckbox.action = #selector(blendChanged)
        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetColors))

        let content = NSStackView(views: [barRow, preview, rowsStack, add, blendCheckbox, reset])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(14, after: barRow)
        content.setCustomSpacing(14, after: rowsStack)
        content.setCustomSpacing(14, after: add)
        NSColorPanel.shared.showsAlpha = true
        addTab("Colors", content: content, stack: colorsStack)
        rebuildRows()
    }

    private func resizeToFit() {
        guard let window, let stack = tabView.selectedTabViewItem?.view?.subviews.first as? NSStackView else { return }
        stack.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        let chrome = NSSize(width: 40, height: 60)  // tab header and margins
        let widest = tabView.tabViewItems.compactMap { ($0.view?.subviews.first as? NSStackView)?.fittingSize.width }.max() ?? fit.width
        let content = NSSize(width: max(widest, 380) + chrome.width, height: fit.height + chrome.height + 16)
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) { resizeToFit() }

    // MARK: Colors editor

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        wells = []
        percentFields = []
        NSColorPanel.shared.setTarget(nil)
        for (i, stop) in editing.stops.enumerated() {
            let well = ColorSwatchButton()
            well.color = NSColor(hex: stop.hex) ?? .gray
            well.tag = i
            well.target = self
            well.action = #selector(swatchClicked(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                well.widthAnchor.constraint(equalToConstant: 36),
                well.heightAnchor.constraint(equalToConstant: 22),
            ])

            let formatter = NumberFormatter()
            formatter.minimum = 0
            formatter.maximum = 100
            formatter.allowsFloats = true
            formatter.maximumFractionDigits = 1
            let field = NSTextField()
            field.formatter = formatter
            field.doubleValue = stop.from
            field.tag = i
            field.delegate = self
            field.isEnabled = i != 0
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true

            let grip = DragHandle()
            grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to reorder")
            grip.contentTintColor = .secondaryLabelColor
            grip.index = i
            var views: [NSView] = [grip, well, NSTextField(labelWithString: "from"), field, NSTextField(labelWithString: "%")]
            for (symbol, delta) in [("chevron.up", -1), ("chevron.down", 1)] {
                let move = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                                    target: self, action: #selector(moveStop(_:)))
                move.bezelStyle = .circular
                move.tag = i
                move.identifier = NSUserInterfaceItemIdentifier(String(delta))
                move.isEnabled = editing.stops.indices.contains(i + delta)
                views.append(move)
            }
            if i != 0 {
                let remove = NSButton(title: "–", target: self, action: #selector(removeStop(_:)))
                remove.tag = i
                remove.bezelStyle = .circular
                views.append(remove)
            }
            rowsStack.addArrangedSubview(NSStackView(views: views))
            wells.append(well)
            percentFields.append(field)
        }
        blendCheckbox.state = editing.blend ? .on : .off
        preview.update(editing)
        resizeToFit()
    }

    /// Records the current colors so the next change can be undone. Repeated calls with the same key
    /// (and nothing else in between) share one undo step.
    private func recordUndo(coalesce key: String? = nil) {
        if let key, key == coalesceKey { return }
        coalesceKey = key
        registerUndo(editing, daily: editingDaily)
    }

    private func registerUndo(_ colors: BarColors, daily: Bool) {
        colorUndo.registerUndo(withTarget: self) { target in
            target.coalesceKey = nil
            target.registerUndo(target.editing, daily: target.editingDaily)
            target.restore(colors, daily: daily)
        }
        colorUndo.setActionName("Edit Colors")
    }

    /// Writes `colors` back to whichever bar they belong to, switching the editor to it.
    private func restore(_ colors: BarColors, daily: Bool) {
        if daily != editingDaily {
            editingDaily = daily
            barSelector.selectedSegment = daily ? 1 : 0
        }
        editing = colors
        if daily { Settings.dailyColors = colors } else { Settings.deadlineColors = colors }
        rebuildRows()
        onChange(false)
    }

    @objc func undo(_ sender: Any?) { colorUndo.undo() }
    @objc func redo(_ sender: Any?) { colorUndo.redo() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { colorUndo }

    private func applyColors() {
        colorsDebounce?.invalidate()
        if editingDaily { Settings.dailyColors = editing } else { Settings.deadlineColors = editing }
        preview.update(editing)
        onChange(false)
    }

    /// Reads the percent fields back into the stops; rebuilds the rows only if the order changed.
    private func commitPercents() {
        colorsDebounce?.invalidate()
        guard percentFields.count == editing.stops.count else { return }
        var updated = editing.stops
        for (i, field) in percentFields.enumerated() where i != 0 {
            updated[i].from = min(max(field.doubleValue, 0), 100)
        }
        let reordered = zip(updated, updated.dropFirst()).contains { $0.from > $1.from }
        updated.sort { $0.from < $1.from }
        let changed = updated != editing.stops
        if changed {
            recordUndo()
            editing.stops = updated
        }
        applyColors()
        if reordered { rebuildRows() }
    }

    private static let namedColors: [(String, NSColor)?] = [
        ("System accent", .controlAccentColor), ("Monochrome accent", .labelColor), nil,
        ("Clear", .clear), ("White", .white), ("Black", .black),
        ("Gray", .systemGray), ("Dark gray", .darkGray), ("Light gray", .lightGray),
        ("Red", .systemRed), ("Green", .systemGreen), ("Blue", .systemBlue),
        ("Yellow", .systemYellow), ("Orange", .systemOrange), ("Purple", .systemPurple),
        ("Brown", .systemBrown), ("Cyan", .systemCyan),
        ("Pink", .systemPink), ("Teal", .systemTeal), ("Indigo", .systemIndigo),
    ]

    @objc private func swatchClicked(_ sender: ColorSwatchButton) {
        pickingIndex = sender.tag
        let current = sender.color.hexString
        let menu = NSMenu()
        var matched = false
        for entry in Self.namedColors {
            guard let (name, color) = entry else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: name, action: #selector(namedColorPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            if color.hexString == current && !matched { item.state = .on; matched = true }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: #selector(customPicked), keyEquivalent: "")
        custom.target = self
        custom.state = matched ? .off : .on
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func namedColorPicked(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        setColor(color, at: pickingIndex)
        wells[pickingIndex].color = color
    }

    @objc private func customPicked() {
        guard wells.indices.contains(pickingIndex) else { return }
        coalesceKey = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = wells[pickingIndex].color
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        guard wells.indices.contains(pickingIndex) else { return }
        setColor(sender.color, at: pickingIndex, coalesce: "panel\(pickingIndex)")
        wells[pickingIndex].color = sender.color
    }

    private func setColor(_ color: NSColor, at index: Int, coalesce key: String? = nil) {
        guard editing.stops.indices.contains(index) else { return }
        recordUndo(coalesce: key)
        editing.stops[index].hex = color.hexString
        applyColors()
    }

    /// Live threshold change from dragging a handle; it stays between its neighbors so the rows never re-sort.
    @discardableResult
    private func dragStop(_ index: Int, to percent: Double) -> Double {
        guard index > 0, editing.stops.indices.contains(index), percentFields.indices.contains(index) else { return percent }
        let lo = editing.stops[index - 1].from
        let hi = index + 1 < editing.stops.count ? editing.stops[index + 1].from : 100
        let value = min(max((percent * 10).rounded() / 10, lo), hi)
        guard value != editing.stops[index].from else { return value }
        recordUndo(coalesce: "drag\(index)")
        editing.stops[index].from = value
        percentFields[index].doubleValue = value
        applyColors()
        return value
    }

    @objc private func addStop() {
        commitPercents()
        let last = editing.stops.last!
        let from = last.from >= 99 ? 100 : (last.from + 100) / 2
        recordUndo()
        editing.stops.append(ColorStop(from: from, hex: last.hex))
        applyColors()
        rebuildRows()
    }

    /// Removes the dragged stop and re-inserts it in `gap` (0...count, counted before removal),
    /// at the midpoint of the two stops it lands between.
    private func dropStop(from: Int, gap: Int) {
        guard editing.stops.count > 1, editing.stops.indices.contains(from), gap != from, gap != from + 1 else { return }
        commitPercents()
        recordUndo()
        let moved = editing.stops.remove(at: from)
        editing.stops[0].from = 0  // the first stop always starts at 0
        let at = gap > from ? gap - 1 : gap
        func mid(_ a: Double, _ b: Double) -> Double { ((a + b) / 2 * 10).rounded() / 10 }
        var stop = moved
        if at == 0 {
            // New first stop; the old first one moves to the middle of the next gap.
            stop.from = 0
            editing.stops[0].from = mid(0, editing.stops.count > 1 ? editing.stops[1].from : 100)
        } else {
            let prev = editing.stops[at - 1].from
            let next = at < editing.stops.count ? editing.stops[at].from : 100
            stop.from = prev >= 99 && at == editing.stops.count ? 100 : mid(prev, next)
        }
        editing.stops.insert(stop, at: at)
        applyColors()
        rebuildRows()
    }

    /// Swaps this stop's color with its neighbor's; the thresholds stay put so the list remains sorted.
    @objc private func moveStop(_ sender: NSButton) {
        let delta = Int(sender.identifier?.rawValue ?? "") ?? 0
        let j = sender.tag + delta
        guard editing.stops.indices.contains(sender.tag), editing.stops.indices.contains(j) else { return }
        commitPercents()
        recordUndo()
        let hex = editing.stops[sender.tag].hex
        editing.stops[sender.tag].hex = editing.stops[j].hex
        editing.stops[j].hex = hex
        applyColors()
        rebuildRows()
    }

    @objc private func removeStop(_ sender: NSButton) {
        guard sender.tag > 0, editing.stops.indices.contains(sender.tag) else { return }
        commitPercents()
        recordUndo()
        editing.stops.remove(at: sender.tag)
        applyColors()
        rebuildRows()
    }

    @objc private func blendChanged() {
        recordUndo()
        editing.blend = blendCheckbox.state == .on
        applyColors()
    }

    @objc private func barChanged() {
        commitPercents()
        editingDaily = barSelector.selectedSegment == 1
        editing = editingDaily ? Settings.dailyColors : Settings.deadlineColors
        rebuildRows()
    }

    @objc private func resetColors() {
        recordUndo()
        UserDefaults.standard.removeObject(forKey: editingDaily ? "dailyColors" : "deadlineColors")
        editing = editingDaily ? .dailyDefault : .deadlineDefault
        rebuildRows()
        onChange(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        tokenField.stringValue = Settings.token ?? ""
        dataSourceField.stringValue = Settings.dataSourceID
        pageField.stringValue = Settings.dailyPageID
        formatField.stringValue = Settings.labelFormat
        labelsCheckbox.state = Settings.showLabels ? .on : .off
        dailyTopCheckbox.state = Settings.dailyOnTop ? .on : .off
        stackCheckbox.state = Settings.stackBars ? .on : .off
        showDeadlineCheckbox.state = Settings.showDeadline ? .on : .off
        showDailyCheckbox.state = Settings.showDaily ? .on : .off
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateEnabledStates()
        editing = editingDaily ? Settings.dailyColors : Settings.deadlineColors
        rebuildRows()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Text edits are applied shortly after typing stops, so each keystroke doesn't trigger a fetch.
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField, percentFields.contains(field) {
            colorsDebounce?.invalidate()
            colorsDebounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.commitPercents() }
            return
        }
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.apply() }
    }

    func windowWillClose(_ notification: Notification) {
        if debounce?.isValid == true { apply() }
        if colorsDebounce?.isValid == true { commitPercents() }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.close()
    }

    @objc private func applyNow() { apply() }

    /// The system owns the login item, so read its state back rather than trusting the checkbox.
    @objc private func toggleLogin() {
        do {
            if loginCheckbox.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        let status = SMAppService.mainApp.status
        loginCheckbox.state = status == .enabled ? .on : .off
        // Disabled by the user in System Settings › Login Items; only they can turn it back on there.
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Stacking needs both bars; with neither shown, the only way back to Settings is reopening the app.
    private func updateEnabledStates() {
        let both = showDeadlineCheckbox.state == .on && showDailyCheckbox.state == .on
        let neither = showDeadlineCheckbox.state == .off && showDailyCheckbox.state == .off
        stackCheckbox.isEnabled = both
        dailyTopCheckbox.isEnabled = both
        if hintRow?.isHidden != !neither {
            hintRow?.isHidden = !neither
            resizeToFit()
        }
    }

    private func apply() {
        debounce?.invalidate()
        let before = [Settings.token ?? "", Settings.dataSourceID, Settings.dailyPageID]
        Settings.token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.dataSourceID = dataSourceField.stringValue
        Settings.dailyPageID = pageField.stringValue
        Settings.labelFormat = formatField.stringValue
        Settings.showLabels = labelsCheckbox.state == .on
        Settings.dailyOnTop = dailyTopCheckbox.state == .on
        Settings.stackBars = stackCheckbox.state == .on
        Settings.showDeadline = showDeadlineCheckbox.state == .on
        Settings.showDaily = showDailyCheckbox.state == .on
        updateEnabledStates()
        onChange(before != [Settings.token ?? "", Settings.dataSourceID, Settings.dailyPageID])
    }
}

/// A thin bar showing the color at every percent, with a draggable Liquid Glass knob for each stop after the first.
/// The knobs are plain subviews that ignore clicks; this view does all the hit-testing and dragging itself.
final class ColorPreviewView: NSView {
    static let height: CGFloat = 28
    private static let inset: CGFloat = 16  // room for a knob hanging off either end
    private static let trackHeight: CGFloat = 4
    private static let grabRadius: CGFloat = 12

    /// Calls `onBegin` when a drag starts and `onDrag` as it moves; `onDrag` returns the value actually applied.
    var onBegin: (() -> Void)?
    var onDrag: ((_ index: Int, _ percent: Double) -> Double)?

    private var colors = BarColors.deadlineDefault
    private var knobs: [KnobView] = []
    private var dragging: Int?

    func update(_ colors: BarColors) {
        self.colors = colors
        needsDisplay = true
        needsLayout = true
    }

    private var track: NSRect {
        NSRect(x: Self.inset, y: bounds.midY - Self.trackHeight / 2, width: bounds.width - 2 * Self.inset, height: Self.trackHeight)
    }

    private func x(for percent: Double) -> CGFloat { track.minX + track.width * percent / 100 }

    override func layout() {
        super.layout()
        let wanted = max(colors.stops.count - 1, 0)
        while knobs.count < wanted {
            let knob = KnobView()
            addSubview(knob)
            knobs.append(knob)
        }
        while knobs.count > wanted { knobs.removeLast().removeFromSuperview() }
        for (n, knob) in knobs.enumerated() {
            knob.isActive = n + 1 == dragging
            let size = n + 1 == dragging ? NSSize(width: 26, height: 20) : NSSize(width: 18, height: 14)
            let frame = NSRect(x: x(for: colors.stops[n + 1].from) - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            if knob.frame.size == size || knob.frame.isEmpty {
                knob.frame = frame
            } else {
                // Growing or shrinking: animate, and keep following the stop while it plays.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    knob.animator().frame = frame
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let width = max(Int(track.width), 1)
        for px in 0..<width {
            colors.color(at: Double(px) / Double(max(width - 1, 1)) * 100).setFill()
            NSRect(x: track.minX + CGFloat(px), y: track.minY, width: 1, height: track.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The first stop is pinned at 0, so only later ones can be grabbed.
    private func knob(at point: NSPoint) -> Int? {
        colors.stops.indices.dropFirst().filter { abs(x(for: colors.stops[$0].from) - point.x) <= Self.grabRadius }
            .min { abs(x(for: colors.stops[$0].from) - point.x) < abs(x(for: colors.stops[$1].from) - point.x) }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = knob(at: convert(event.locationInWindow, from: nil))
        guard dragging != nil else { return }
        onBegin?()
        needsLayout = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragging else { return }
        let px = convert(event.locationInWindow, from: nil).x
        _ = onDrag?(index, Double((px - track.minX) / track.width * 100))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        needsLayout = true
    }
}

/// A capsule thumb like the system slider's: solid white at rest, clear Liquid Glass while dragged; clicks fall through to `ColorPreviewView`.
/// The white sits on top of the glass rather than in its `contentView`, which the glass would tint gray.
final class KnobView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = 100  // always fully round ends, so any frame is a capsule
        glass.alphaValue = 0
        glass.autoresizingMask = [.width, .height]
        white.wantsLayer = true
        white.layer?.backgroundColor = NSColor.white.cgColor
        white.layer?.cornerCurve = .continuous
        white.layer?.shadowColor = NSColor.black.cgColor
        white.layer?.shadowOpacity = 0.3
        white.layer?.shadowRadius = 2
        white.layer?.shadowOffset = .zero
        white.autoresizingMask = [.width, .height]
        addSubview(glass)
        addSubview(white)
    }

    private let glass = NSGlassEffectView()
    private let white = NSView()

    override func layout() {
        super.layout()
        white.layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    /// Cross-fades from the white fill to the glass lens while the knob is being dragged.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                white.animator().alphaValue = isActive ? 0 : 1
                glass.animator().alphaValue = isActive ? 1 : 0
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The grip at the start of each stop row; dragging it picks up the whole row.
final class DragHandle: NSImageView, NSDraggingSource {
    var index = 0

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let row = superview, let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return }
        row.cacheDisplay(in: row.bounds, to: rep)
        let image = NSImage(size: row.bounds.size)
        image.addRepresentation(rep)
        let item = NSPasteboardItem()
        item.setString(String(index), forType: ReorderableStackView.type)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(row.convert(row.bounds, to: self), contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }
}

/// Vertical stack whose rows can be dropped onto each other; reports the source row and the drop gap.
final class ReorderableStackView: NSStackView {
    static let type = NSPasteboard.PasteboardType("dev.zphrs.DeadlineProgress.stop-row")
    var onMove: ((_ from: Int, _ gap: Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.type])
    }

    required init?(coder: NSCoder) { fatalError() }

    private let indicator = NSView()

    /// The gap (0...rows.count) nearest the pointer, counted before the dragged row is removed.
    private func gap(_ info: NSDraggingInfo) -> Int {
        let y = convert(info.draggingLocation, from: nil).y
        return arrangedSubviews.filter { $0.frame.midY > y }.count
    }

    private func showIndicator(at gap: Int) {
        let rows = arrangedSubviews
        guard !rows.isEmpty else { return }
        let y = gap < rows.count ? rows[gap].frame.maxY + spacing / 2 : rows[rows.count - 1].frame.minY - spacing / 2
        if indicator.superview == nil {
            indicator.wantsLayer = true
            indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            addSubview(indicator)
        }
        indicator.frame = NSRect(x: 0, y: y - 1, width: bounds.width, height: 2)
        indicator.isHidden = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        showIndicator(at: gap(sender))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        showIndicator(at: gap(sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { indicator.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { indicator.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = sender.draggingPasteboard.string(forType: Self.type), let from = Int(text) else { return false }
        indicator.isHidden = true
        onMove?(from, gap(sender))
        return true
    }
}

/// A color chip that fires its action on click so the controller can show a menu of named colors.
final class ColorSwatchButton: NSButton {
    var color = NSColor.gray { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.white.setFill()  // so transparent colors read as translucent
        bounds.fill()
        color.setFill()
        bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shape.stroke()
    }
}
