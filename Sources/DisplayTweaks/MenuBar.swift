import AppKit

/// The status item and its menu (R-13, R-14). The menu is rebuilt each time it opens (DD-8) from the controller's
/// cached state, with no key equivalents. Each display is a header item drawn by `DisplayRowView` that opens in place
/// into plain option items; everything else is plain NSMenuItems. Copy and icon state come from `Displays`.
final class MenuBar: NSObject, NSMenuDelegate {
    #if DEBUG
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) // room for "DEV"
    #else
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    #endif
    let menu = NSMenu()

    /// Seam: tests hide the status item.
    static var showsStatusItem = true

    let controller: HiDPIController
    /// The rows the open menu shows, and the headers clicked open or shut since launch (`Displays.isOpen`).
    private var shown: [Displays.Row] = []
    private var toggled: Set<String> = []
    /// While the menu is open, a change rebuilds it in place, so an option's new state shows without reopening.
    private var isOpen = false
    /// Marks option items, so closing a header removes exactly its own.
    private static let optionTag = 1

    init(controller: HiDPIController) {
        self.controller = controller
        super.init()
        controller.onChange = { [weak self] in
            guard let self else { return }
            isOpen ? menuNeedsUpdate(menu) : updateImage()
        }
        item.isVisible = Self.showsStatusItem
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        #if DEBUG
        item.button?.title = "DEV"
        item.button?.imagePosition = .imageLeading
        #endif
        updateImage()
    }

    /// R-14 and the Status icon wireframe: 16 pt regular template images, each state with its own description.
    /// Precedence (`Displays.icon`): unavailable > any Failed > normal.
    private func updateImage() {
        let icon = controller.icon
        let image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.description)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    /// Wireframe order: debug block (Dev only), the display rows or the empty / unavailable rows, Turn Off All,
    /// the app block, Quit; separators between the groups.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateImage()
        menu.removeAllItems()
        menu.minimumWidth = 0
        #if DEBUG
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        add("DisplayTweaks Dev \(version) (debug)").isEnabled = false
        menu.addItem(.separator())
        #endif
        shown = controller.rows
        if !controller.isAvailable { // R-11
            add(Displays.unavailableTitle).isEnabled = false
            add(Displays.unavailableInfo).isEnabled = false
        } else if shown.isEmpty {
            add(Displays.emptyTitle).isEnabled = false
            add(Displays.emptyInfo).isEnabled = false
        } else {
            menu.addItem(.sectionHeader(title: Displays.listTitle))
        }
        var shut: [NSMenuItem] = []
        for row in shown { // R-1, R-13: a header per display, opened into its options
            let header = add(row.title, row.options.isEmpty ? nil : #selector(toggleOpen(_:)))
            header.representedObject = row.uuid
            header.isEnabled = !row.options.isEmpty // nothing to open: Not available and no Disable Display
            let open = Displays.isOpen(row.uuid, rowCount: shown.count, toggled: toggled)
            header.view = DisplayRowView(row: row, isOpen: open) { [weak self, weak header] in header.map { self?.toggleOpen($0) } }
            insertOptions(row, after: header)
            if !open { shut.append(header) }
        }
        menu.addItem(.separator())
        add(Displays.turnOffAllTitle, #selector(turnOffAll)).isEnabled = Displays.canTurnOffAll(shown) // R-9
        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLaunchAtLogin), on: LaunchAtLogin.isEnabled)
        add("Automatic Updates", #selector(toggleUpdates), on: Updater.isEnabled)
        add("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        add("Quit DisplayTweaks", #selector(quit))
        // Measured with every display open, so opening one never resizes the menu.
        menu.minimumWidth = menu.size.width
        shut.forEach(removeOptions)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.state = on ? .on : .off
        menu.addItem(item)
        return item
    }

    private func insertOptions(_ row: Displays.Row, after header: NSMenuItem) {
        var index = menu.index(of: header)
        let settling = controller.settling.contains(row.uuid) // busy until its disable or enable has settled
        for option in row.options {
            let action: Selector? = switch option.action {
            case .hiDPI: #selector(toggle(_:))
            case .disable: #selector(disable(_:))
            case .enable: #selector(enable(_:))
            case nil: nil
            }
            let item = NSMenuItem(title: option.title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.state = option.isOn ? .on : .off
            item.isEnabled = option.isEnabled && action != nil && !settling
            item.indentationLevel = action == nil ? 2 : 1
            item.representedObject = row.uuid
            item.tag = Self.optionTag
            let busy = settling && (option.action == .disable || option.action == .enable)
            item.view = OptionRowView(item: item, busy: busy) // a click keeps the menu open
            index += 1
            menu.insertItem(item, at: index)
        }
    }

    // MARK: Actions

    /// A header click opens or shuts the display's options in place; the menu stays open (DD-8).
    @objc private func toggleOpen(_ header: NSMenuItem) {
        guard let uuid = header.representedObject as? String, let row = shown.first(where: { $0.uuid == uuid }) else { return }
        toggled.formSymmetricDifference([uuid])
        let open = Displays.isOpen(uuid, rowCount: shown.count, toggled: toggled)
        (header.view as? DisplayRowView)?.isOpen = open
        open ? insertOptions(row, after: header) : removeOptions(after: header)
    }

    private func removeOptions(after header: NSMenuItem) {
        let next = menu.index(of: header) + 1
        while next < menu.numberOfItems, menu.item(at: next)?.tag == Self.optionTag { menu.removeItem(at: next) }
    }

    @objc private func toggle(_ sender: NSMenuItem) { (sender.representedObject as? String).map(controller.toggle) }
    @objc private func disable(_ sender: NSMenuItem) { (sender.representedObject as? String).map(controller.disable) }
    @objc private func enable(_ sender: NSMenuItem) { (sender.representedObject as? String).map(controller.enable) }
    @objc private func turnOffAll() { controller.turnOffAll() }
    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.toggle() }
    @objc private func toggleUpdates() { Updater.toggle() }
    @objc private func checkForUpdates() { Updater.check(manual: true) }
    @objc private func quit() { Env.terminate() } // R-12: no display changes
}

/// A display's header in the menu: symbol, name, Main badge, one-line status and a chevron when it opens. It draws
/// its own highlight (menus don't for view items) and handles the click itself, so the menu stays open. The item's
/// title stays set for VoiceOver and type-select; Return on a highlighted header sends the item's action instead.
final class DisplayRowView: NSView {
    let row: Displays.Row
    var isOpen: Bool { didSet { needsDisplay = true; setAccessibilityExpanded(isOpen) } }
    private let onClick: () -> Void

    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let statusFont = NSFont.systemFont(ofSize: 11)
    private static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let textX: CGFloat = 44

    init(row: Displays.Row, isOpen: Bool, onClick: @escaping () -> Void) {
        self.row = row
        self.isOpen = isOpen
        self.onClick = onClick
        let name = (row.name as NSString).size(withAttributes: [.font: Self.nameFont]).width + (row.isMain ? 44 : 0)
        let status = (row.status as NSString).size(withAttributes: [.font: Self.statusFont]).width
        super.init(frame: NSRect(x: 0, y: 0, width: max(260, Self.textX + max(name, status) + 40), height: 42))
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(row.title), \(row.status)")
        setAccessibilityEnabled(!row.options.isEmpty)
        if !row.options.isEmpty { setAccessibilityExpanded(isOpen) }
    }

    required init?(coder: NSCoder) { nil }

    var isOpenable: Bool { !row.options.isEmpty }
    private var isHighlighted: Bool { isOpenable && enclosingMenuItem?.isHighlighted == true }

    override func mouseUp(with event: NSEvent) { if isOpenable { onClick() } }
    override func accessibilityPerformPress() -> Bool {
        if isOpenable { onClick() }
        return isOpenable
    }

    /// The approved mockup's monitor: a 26 pt outline screen (21 × 13.5, radius 2) on a stand, 1.5 pt strokes,
    /// drawn in the mockup's top-down coordinates.
    private func drawMonitor(color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let flip = NSAffineTransform()
        flip.translateX(by: 10, yBy: (bounds.height + 26) / 2)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        color.setStroke()
        let path = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 4, width: 21, height: 13.5), xRadius: 2, yRadius: 2)
        path.move(to: NSPoint(x: 9.5, y: 22))
        path.line(to: NSPoint(x: 16.5, y: 22))
        path.move(to: NSPoint(x: 13, y: 17.5))
        path.line(to: NSPoint(x: 13, y: 22))
        path.lineWidth = 1.5
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        let lit = isHighlighted
        if lit {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        let ink: NSColor = lit ? .selectedMenuItemTextColor : .labelColor
        let faint: NSColor = lit ? .selectedMenuItemTextColor : .secondaryLabelColor
        let dimmed = row.state == .disabled

        drawMonitor(color: dimmed ? faint.withAlphaComponent(0.25) : faint)

        let name = NSAttributedString(string: row.name, attributes: [.font: Self.nameFont,
                                                                      .foregroundColor: dimmed ? faint : ink])
        let nameSize = name.size()
        let nameY = bounds.height / 2 + 1
        name.draw(at: NSPoint(x: Self.textX, y: nameY))
        if row.isMain {
            let badge = NSAttributedString(string: "Main", attributes: [.font: Self.badgeFont,
                                                                         .foregroundColor: lit ? ink : NSColor.controlAccentColor])
            let b = badge.size()
            let rect = NSRect(x: Self.textX + nameSize.width + 6, y: nameY + (nameSize.height - b.height - 2) / 2,
                              width: b.width + 10, height: b.height + 2)
            (lit ? NSColor.white.withAlphaComponent(0.25) : NSColor.controlAccentColor.withAlphaComponent(0.15)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            badge.draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 1))
        }
        NSAttributedString(string: row.status, attributes: [.font: Self.statusFont, .foregroundColor: faint])
            .draw(at: NSPoint(x: Self.textX, y: bounds.height / 2 - 15))

        guard isOpenable else { return }
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [faint]))
        if let chevron = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig) {
            let size = chevron.size
            chevron.draw(in: NSRect(x: bounds.width - 22 - size.width / 2, y: (bounds.height - size.height) / 2,
                                    width: size.width, height: size.height))
        }
    }
}

/// A display option: HiDPI, Disable Display, Enable Display, or an info line (no action). Plain items close the
/// menu when chosen; this view sends the item's action itself, so the menu stays open and is rebuilt in place by `onChange`.
/// While the action runs (a switch blocks the main thread) the row shows a spinner and takes no clicks, including
/// the ones queued meanwhile.
/// Title, state and enabled stay set on the item for VoiceOver, type-select and the outline.
final class OptionRowView: NSView {
    private static let font = NSFont.menuFont(ofSize: 13)
    private static let infoFont = NSFont.systemFont(ofSize: 11)
    /// Uptime when the last action finished; clicks from before it were queued while it ran.
    private static var readyAt: TimeInterval = 0
    private var spinner: NSProgressIndicator?
    var isBusy: Bool { spinner != nil }

    init(item: NSMenuItem, busy: Bool = false) {
        let width = (item.title as NSString).size(withAttributes: [.font: Self.font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: DisplayRowView.textX + width + 20,
                                   height: item.action == nil ? 18 : 22))
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(item.action == nil ? .staticText : .checkBox)
        setAccessibilityLabel(item.title)
        if item.action != nil { setAccessibilityValue(item.state == .on) }
        setAccessibilityEnabled(item.isEnabled)
        if busy { spin() }
    }

    required init?(coder: NSCoder) { nil }

    private var isHighlighted: Bool { !isBusy && enclosingMenuItem.map { $0.isEnabled && $0.isHighlighted } == true }

    /// Shows the spinner at once, then runs the action on the next turn: it rebuilds the menu (fresh rows show the
    /// new state), which would otherwise remove this view mid-click. A row left in place (menu closed) clears itself.
    @discardableResult
    func press() -> Bool {
        guard !isBusy, let item = enclosingMenuItem, item.isEnabled, let action = item.action else { return false }
        spin()
        display() // drawn before the switch blocks the main thread
        CATransaction.flush()
        DispatchQueue.main.async {
            NSApp.sendAction(action, to: item.target, from: item)
            Self.readyAt = ProcessInfo.processInfo.systemUptime
            self.spinner?.removeFromSuperview()
            self.spinner = nil
            self.setAccessibilityEnabled(item.isEnabled)
            self.needsDisplay = true
        }
        return true
    }

    private func spin() {
        let spinner = NSProgressIndicator(frame: NSRect(x: DisplayRowView.textX - 20, y: (bounds.height - 16) / 2,
                                                        width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.usesThreadedAnimation = true
        addSubview(spinner)
        spinner.startAnimation(nil)
        self.spinner = spinner
        setAccessibilityEnabled(false)
    }

    override func mouseUp(with event: NSEvent) { if event.timestamp >= Self.readyAt { press() } }
    override func accessibilityPerformPress() -> Bool { press() }

    override func draw(_ dirtyRect: NSRect) {
        guard let item = enclosingMenuItem else { return }
        let lit = isHighlighted
        if lit {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let ink: NSColor = lit ? .selectedMenuItemTextColor
            : item.isEnabled && !isBusy ? .labelColor : item.action == nil ? .secondaryLabelColor : .tertiaryLabelColor
        let font = item.action == nil ? Self.infoFont : Self.font
        let title = NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: ink])
        let y = (bounds.height - title.size().height) / 2
        title.draw(at: NSPoint(x: DisplayRowView.textX, y: y))
        guard item.state == .on, !isBusy else { return }
        NSAttributedString(string: "\u{2713}", attributes: [.font: Self.font, .foregroundColor: ink])
            .draw(at: NSPoint(x: DisplayRowView.textX - 16, y: y))
    }
}
