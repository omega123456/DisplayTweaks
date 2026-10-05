import AppKit
import SnapshotTesting
import Testing
@testable import DisplayTweaks

extension Desktop {
    @MainActor @Suite struct MenuBarTests {
        let h = Harness()

        func choose(_ title: String, in menu: NSMenu) {
            guard let item = menu.items.first(where: { $0.title == title }) else { Issue.record("no \(title)"); return }
            NSApp.sendAction(item.action!, to: item.target, from: item) // never performClick (CLAUDE.md pitfalls)
        }

        /// Outline references (DD-8). Tests are debug builds, so every reference starts with the Dev debug row.
        func dsm(on: Bool = false) -> FakeDisplayWorld.Display { FakeDisplayWorld.dell(1, "DELL S2725DSM", x: 0, on: on) }
        func dc(on: Bool = false, hz: Int = 144) -> FakeDisplayWorld.Display { FakeDisplayWorld.dell(2, "DELL S2725DC", x: 2560, on: on, hz: hz) }
        let ipad = FakeDisplayWorld.ipad(3, x: 5120)

        /// Outline references (DD-8). Tests are debug builds, so every reference starts with the Dev debug row.
        enum Case: String, CaseIterable {
            case empty            // no external display
            case unavailable      // R-11
            case appBlockToggled  // Launch at Login on, Automatic Updates off
            case twoDisplays      // DSM On, DC Off
            case singleDisplay    // DSM On
            case failedNoMode     // DSM On, DC Failed (no HiDPI mode at 100 Hz), iPad Not available
            case failedRejected   // DSM Off, DC Failed (macOS rejected the change)
            case notAvailable     // DC Off, iPad Not available
            case onlyIneligible   // iPad alone
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
            case .twoDisplays: h.world.displays = [dsm(on: true), dc()]
            case .singleDisplay: h.world.displays = [dsm(on: true)]
            case .failedNoMode: h.world.displays = [dsm(on: true), dc(hz: 100), ipad]
            case .failedRejected:
                h.world.displays = [dsm(), dc()]
                h.world.error = .illegalArgument
            case .notAvailable: h.world.displays = [dc(), ipad]
            case .onlyIneligible: h.world.displays = [ipad]
            }
            let bar = MenuBar(controller: h.controller())
            if c == .failedNoMode || c == .failedRejected { bar.controller.toggle("DELL S2725DC-UUID") }
            bar.menuNeedsUpdate(bar.menu)
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
            choose("DELL S2725DC — HiDPI", in: bar.menu)
            #expect(h.world.switches == ["2:113"])
            bar.menuNeedsUpdate(bar.menu)
            #expect(bar.menu.items.first { $0.title == "DELL S2725DC — HiDPI" }?.state == .on)
            choose(Displays.turnOffAllTitle, in: bar.menu)
            #expect(h.world.switches == ["2:113", "1:78", "2:78"])
            bar.menuNeedsUpdate(bar.menu)
            #expect(bar.menu.items.first { $0.title == Displays.turnOffAllTitle }?.isEnabled == false)
            #expect(bar.item.button?.image?.accessibilityDescription == "DisplayTweaks")
            // A failure changes the icon through the controller's notification, without opening the menu.
            h.world.error = .illegalArgument
            choose("DELL S2725DC — HiDPI", in: bar.menu)
            #expect(bar.item.button?.image?.accessibilityDescription == "DisplayTweaks, HiDPI failed")
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
