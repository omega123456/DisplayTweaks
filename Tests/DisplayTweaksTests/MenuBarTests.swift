import AppKit
import SnapshotTesting
import Testing
@testable import DisplayTweaks

extension Desktop {
    @MainActor @Suite struct MenuBarTests {
        let h = Harness()

        /// Sends an item's action; `of`: the display UUID an option item belongs to.
        func choose(_ title: String, of uuid: String? = nil, in menu: NSMenu) {
            guard let item = menu.items.first(where: { $0.title == title && (uuid == nil || $0.representedObject as? String == uuid) })
            else { Issue.record("no \(title)"); return }
            NSApp.sendAction(item.action!, to: item.target, from: item) // never performClick (CLAUDE.md pitfalls)
        }

        let dsmID = "DELL S2725DSM-UUID", dcID = "DELL S2725DC-UUID"

        /// Outline references (DD-8). Tests are debug builds, so every reference starts with the Dev debug row.
        func dsm(on: Bool = false) -> FakeDisplayWorld.Display { FakeDisplayWorld.dell(1, "DELL S2725DSM", x: 0, on: on) }
        func dc(on: Bool = false, hz: Int = 144) -> FakeDisplayWorld.Display { FakeDisplayWorld.dell(2, "DELL S2725DC", x: 2560, on: on, hz: hz) }
        let ipad = FakeDisplayWorld.ipad(3, x: 5120)

        /// Outline references (DD-8). Tests are debug builds, so every reference starts with the Dev debug row.
        enum Case: String, CaseIterable {
            case empty            // no external display
            case unavailable      // R-11
            case appBlockToggled  // Launch at Login on, Automatic Updates off
            case twoDisplays      // DSM On, DC Off, both shut
            case twoDisplaysOpen  // the same, both opened
            case singleDisplay    // DSM On, open by itself, the last active display
            case withBuiltIn      // a built-in and the DSM: Disable Display allowed
            case noDisable        // DSM On, the enable/disable function missing
            case failedNoMode     // DSM On, DC Failed (no HiDPI mode at 100 Hz) and opened, iPad Not available
            case failedRejected   // DSM Off, DC Failed (macOS rejected the change)
            case notAvailable     // DC Off and opened, iPad Not available (only Disable Display)
            case onlyIneligible   // iPad alone
            case oneDisabled      // DSM On, DC disabled, both opened
            case enableFailed     // DSM On, DC disabled and its enable failed, opened
            case uhd              // a 4K panel On at 3360 × 1890 (no native 2× mode), open by itself
        }

        /// The menu and its status icon description for a case.
        func menu(for c: Case) -> MenuBar {
            h.available = c != .unavailable
            h.world.main = 1 // the DSM, when present
            switch c {
            case .empty, .unavailable: break
            case .appBlockToggled:
                h.loginStatus = .enabled
                h.defaults.set(true, forKey: "autoUpdateDisabled")
            case .twoDisplays, .twoDisplaysOpen, .oneDisabled, .enableFailed: h.world.displays = [dsm(on: true), dc()]
            case .singleDisplay: h.world.displays = [dsm(on: true)]
            case .withBuiltIn:
                var builtIn = FakeDisplayWorld.dell(9, "Built-in", x: -1512)
                builtIn.isBuiltIn = true
                h.world.displays = [builtIn, dsm(on: true)]
            case .noDisable:
                h.world.canDisable = false
                h.world.displays = [dsm(on: true)]
            case .failedNoMode: h.world.displays = [dsm(on: true), dc(hz: 100), ipad]
            case .failedRejected:
                h.world.displays = [dsm(), dc()]
                h.world.error = .illegalArgument
            case .notAvailable: h.world.displays = [dc(), ipad]
            case .onlyIneligible: h.world.displays = [ipad]
            case .uhd: h.world.displays = [FakeDisplayWorld.uhd(5, "ASUS CG32U", x: 0, on: true)]
            }
            let bar = MenuBar(controller: h.controller())
            if c == .failedNoMode || c == .failedRejected { bar.controller.toggle(dcID) }
            if c == .oneDisabled || c == .enableFailed { bar.controller.disable(dcID) }
            if c == .enableFailed {
                h.world.error = .illegalArgument
                bar.controller.enable(dcID)
            }
            bar.menuNeedsUpdate(bar.menu)
            let open: [String] = switch c {
            case .twoDisplaysOpen, .oneDisabled: ["DELL S2725DSM (Main)", "DELL S2725DC"]
            case .failedNoMode, .notAvailable, .enableFailed: ["DELL S2725DC"]
            default: []
            }
            for title in open { choose(title, in: bar.menu) }
            return bar
        }

        @Test(arguments: Case.allCases)
        func menu(_ c: Case) {
            let bar = menu(for: c)
            assertSnapshot(of: outline(bar.menu), as: .lines, named: c.rawValue, testName: "MenuBar")
        }

        /// R-14: symbol and description per state; precedence unavailable > Failed > normal.
        @Test func statusIcons() {
            let expected: [Case: (String, String)] = [
                .empty: ("display", "DisplayTweaks"),
                .twoDisplays: ("display", "DisplayTweaks, HiDPI on"),
                .failedNoMode: ("display.trianglebadge.exclamationmark", "DisplayTweaks, HiDPI failed"),
                .onlyIneligible: ("display", "DisplayTweaks"),
                .unavailable: ("exclamationmark.triangle", "DisplayTweaks, unavailable"),
            ]
            for (c, (symbol, description)) in expected {
                let bar = menu(for: c)
                #expect(bar.item.button?.image?.accessibilityDescription == description, "\(c)")
                #expect(Displays.icon(available: h.available, bar.controller.rows.map(\.state)).symbol == symbol, "\(c)")
                h.world.displays = []
                h.world.error = .success
            }
        }

        @Test func displayActions() {
            h.world.displays = [dsm(on: true), dc()]
            let bar = MenuBar(controller: h.controller())
            bar.menuNeedsUpdate(bar.menu)
            #expect(bar.item.button?.image?.accessibilityDescription == "DisplayTweaks, HiDPI on")
            choose("DELL S2725DC", in: bar.menu) // opens in place
            choose("HiDPI", of: dcID, in: bar.menu)
            #expect(h.world.switches == ["2:113"])
            bar.menuNeedsUpdate(bar.menu) // the menu reopens with the DC still open
            #expect(bar.menu.items.first { $0.title == "HiDPI" && $0.representedObject as? String == dcID }?.state == .on)
            choose(Displays.turnOffAllTitle, in: bar.menu)
            #expect(h.world.switches == ["2:113", "1:78", "2:78"])
            bar.menuNeedsUpdate(bar.menu)
            #expect(bar.menu.items.first { $0.title == Displays.turnOffAllTitle }?.isEnabled == false)
            #expect(bar.item.button?.image?.accessibilityDescription == "DisplayTweaks")
            // A failure changes the icon through the controller's notification, without opening the menu.
            h.world.error = .illegalArgument
            choose("HiDPI", of: dcID, in: bar.menu)
            #expect(bar.item.button?.image?.accessibilityDescription == "DisplayTweaks, HiDPI failed")
        }

        /// Headers open and shut in place, removing exactly their own options; the click path and VoiceOver's press
        /// go through the header view; an iPad header (no HiDPI) opens to Disable Display.
        @Test func openAndShut() {
            h.world.displays = [dsm(on: true), dc(), ipad]
            h.world.main = 1
            let bar = MenuBar(controller: h.controller())
            bar.menuNeedsUpdate(bar.menu)
            let shut = outline(bar.menu)
            let width = bar.menu.size.width
            #expect(bar.menu.minimumWidth == width && width > 0)
            let header = { (title: String) in bar.menu.items.first { $0.title == title }!.view as! DisplayRowView }
            #expect(header("DELL S2725DC").accessibilityPerformPress())
            #expect(header("DELL S2725DC").isOpen && header("DELL S2725DC").isAccessibilityExpanded())
            #expect(bar.menu.items.contains { $0.title == Displays.disableTitle && $0.representedObject as? String == dcID })
            #expect(bar.menu.size.width == width) // opening doesn't resize the menu
            header("DELL S2725DSM (Main)").mouseUp(with: NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0)!)
            #expect(bar.menu.items.filter { $0.title == Displays.disableTitle }.count == 2)
            choose("DELL S2725DC", in: bar.menu)
            choose("DELL S2725DSM (Main)", in: bar.menu)
            #expect(outline(bar.menu) == shut)
            #expect(header("iPad").isOpenable && header("iPad").accessibilityPerformPress())
            #expect(bar.menu.items.contains { $0.title == Displays.disableTitle && $0.representedObject as? String == "IPAD-UUID" })
            choose("iPad", in: bar.menu)
            #expect(header("iPad").accessibilityLabel() == "iPad, HiDPI not available")
            // Drawing (open, shut, Main badge, Disabled) runs offscreen without a menu.
            for view in [header("DELL S2725DSM (Main)"), header("DELL S2725DC"), header("iPad")] {
                view.isOpen.toggle()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
            }
        }

        /// With neither HiDPI nor Disable Display to offer, a header doesn't open.
        @Test func headerWithNothingToOffer() {
            h.world.canDisable = false
            h.world.displays = [dsm(on: true), ipad]
            let bar = MenuBar(controller: h.controller())
            bar.menuNeedsUpdate(bar.menu)
            let item = bar.menu.items.first { $0.title == "iPad" }!
            let view = item.view as! DisplayRowView
            #expect(!item.isEnabled && !view.isOpenable && !view.accessibilityPerformPress())
        }

        @Test func disableAndEnable() {
            h.world.displays = [dsm(on: true), dc(on: true)]
            h.world.main = 1
            let bar = MenuBar(controller: h.controller())
            bar.menuNeedsUpdate(bar.menu)
            choose("DELL S2725DC", in: bar.menu)
            choose(Displays.disableTitle, of: dcID, in: bar.menu)
            #expect(h.world.enables == ["2:off"])
            bar.menuNeedsUpdate(bar.menu)
            #expect(bar.menu.items.first { $0.title == Displays.disableTitle && $0.representedObject as? String == dsmID } == nil)
            choose("DELL S2725DSM (Main)", in: bar.menu)
            #expect(bar.menu.items.first { $0.title == Displays.disableTitle && $0.representedObject as? String == dsmID }?.isEnabled == false)
            choose(Displays.enableTitle, of: dcID, in: bar.menu)
            #expect(h.world.enables == ["2:off", "2:on"])
        }

        @Test func statusIcon() {
            let bar = MenuBar(controller: h.controller())
            #expect(bar.item.button?.title == "DEV")
            #expect(bar.item.button?.image?.accessibilityDescription == "DisplayTweaks")
            #expect(bar.item.button?.image?.isTemplate == true)

            // The functions turn out unavailable: the warning icon with its own description, and the unavailable rows.
            h.available = false
            bar.menuNeedsUpdate(bar.menu)
            #expect(bar.item.button?.image?.accessibilityDescription == "DisplayTweaks, unavailable")
            #expect(bar.menu.items.map(\.title).contains("This version of macOS doesn\u{2019}t support it."))
            #expect(!bar.menu.items.contains { $0.keyEquivalent != "" })
        }

        @Test func appBlock() {
            let bar = MenuBar(controller: h.controller())
            bar.menuNeedsUpdate(bar.menu)

            // Launch at Login: registering may need approval in System Settings; on again unregisters.
            choose("Launch at Login", in: bar.menu)
            #expect(h.loginCalls == ["register", "settings"])
            choose("Launch at Login", in: bar.menu) // requires approval: settings again
            h.loginStatus = .enabled
            bar.menuNeedsUpdate(bar.menu)
            #expect(bar.menu.items.first { $0.title == "Launch at Login" }?.state == .on)
            choose("Launch at Login", in: bar.menu)
            h.loginError = CocoaError(.featureUnsupported)
            choose("Launch at Login", in: bar.menu)
            #expect(h.loginCalls == ["register", "settings", "settings", "unregister", "register"])
            #expect(h.log.contains("launch at login failed"))

            // Updates: a development build can't update.
            choose("Check for Updates…", in: bar.menu)
            #expect(h.notices == ["Updates unavailable"])
            choose("Automatic Updates", in: bar.menu)
            #expect(!Updater.isEnabled)
            choose("Automatic Updates", in: bar.menu)
            #expect(Updater.isEnabled)

            choose("Quit DisplayTweaks", in: bar.menu)
            #expect(h.terminations == 1)
        }
    }

    @MainActor @Suite struct AppTests {
        let h = Harness()

        @Test func launch() {
            let app = AppDelegate()
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            #expect(app.menuBar != nil && app.store != nil && app.controller != nil)
            #expect(h.log.contains("DisplayTweaks started pid=\(getpid()) private functions available"))
        }

        @Test func eventLog() {
            EventLog.write("hello")
            #expect(h.log.contains(" hello\n"))
            EventLog.removeFile()
            #expect(!FileManager.default.fileExists(atPath: EventLog.url.path))
        }
    }
}
