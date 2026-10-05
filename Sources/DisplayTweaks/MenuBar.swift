import AppKit

/// The status item and its menu (R-13, R-14). The menu is rebuilt each time it opens (DD-8) from the controller's
/// cached state: plain NSMenuItems, no key equivalents, no custom views. Copy and icon state come from `Displays`.
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

    init(controller: HiDPIController) {
        self.controller = controller
        super.init()
        controller.onChange = { [weak self] in self?.updateImage() }
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

    /// Wireframe order: debug block (Dev only), the display rows or the empty / unavailable rows, Turn Off All,
    /// the app block, Quit; separators between the groups.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateImage()
        menu.removeAllItems()
        #if DEBUG
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        add("DisplayTweaks Dev \(version) (debug)").isEnabled = false
        menu.addItem(.separator())
        #endif
        let rows = controller.rows
        if !controller.isAvailable { // R-11
            add(Displays.unavailableTitle).isEnabled = false
            add(Displays.unavailableInfo).isEnabled = false
        } else if rows.isEmpty {
            add(Displays.emptyTitle).isEnabled = false
            add(Displays.emptyInfo).isEnabled = false
        }
        for row in rows { // R-1, R-13: a toggle and an indented, disabled info row per display
            let toggle = add(row.title, #selector(toggle(_:)), on: row.state == .on)
            toggle.representedObject = row.uuid
            toggle.isEnabled = row.isEnabled // Not available: dimmed (R-2)
            let info = add(row.info)
            info.isEnabled = false
            info.indentationLevel = 1
        }
        menu.addItem(.separator())
        add(Displays.turnOffAllTitle, #selector(turnOffAll)).isEnabled = Displays.canTurnOffAll(rows) // R-9
        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLaunchAtLogin), on: LaunchAtLogin.isEnabled)
        add("Automatic Updates", #selector(toggleUpdates), on: Updater.isEnabled)
        add("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        add("Quit DisplayTweaks", #selector(quit))
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.state = on ? .on : .off
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func toggle(_ sender: NSMenuItem) { (sender.representedObject as? String).map(controller.toggle) }
    @objc private func turnOffAll() { controller.turnOffAll() }
    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.toggle() }
    @objc private func toggleUpdates() { Updater.toggle() }
    @objc private func checkForUpdates() { Updater.check(manual: true) }
    @objc private func quit() { Env.terminate() } // R-12: no display changes
}
