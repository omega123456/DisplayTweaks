import AppKit
import ServiceManagement
import Testing
@testable import DisplayTweaks

/// Every test that swaps the global seams (`Env`, `DisplaySystem.backend`, …) is nested in this suite, so none run concurrently.
@Suite(.serialized) struct Desktop {}

/// Own notification center (system workspace events, such as wake, never arrive).
final class FakeWorkspace: NSWorkspace {
    let center = NotificationCenter()
    override var notificationCenter: NotificationCenter { center }
}

/// Lets main-queue work (async deliveries, timers) run.
func settle(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }

/// Installs fresh fakes behind every seam. One per test.
@MainActor
final class Harness {
    let ws = FakeWorkspace()
    var defaults: UserDefaults
    /// What the fake `DisplaySystem` reports for the three private functions (R-11).
    var available = true
    var activations = 0, terminations = 0
    var loginStatus = SMAppService.Status.notRegistered
    var loginCalls: [String] = []
    var loginError: Error?
    var notices: [String] = []
    var asks: [String] = []
    var relaunches: [URL] = []
    let dir: URL
    let world = FakeDisplayWorld()

    init() {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayTweaksTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "local.displaytweaks.tests")!
        defaults.removePersistentDomain(forName: "local.displaytweaks.tests")

        Env.workspace = ws
        Env.defaults = defaults
        Env.activate = { [unowned self] in activations += 1 }
        Env.terminate = { [unowned self] in terminations += 1 }
        DisplaySystem.backend = world.backend(available: { [unowned self] in available })
        DisplaySystem.handler = { _, _ in }
        MenuBar.showsStatusItem = false
        LaunchAtLogin.service = .init(
            status: { [unowned self] in loginStatus },
            register: { [unowned self] in
                loginCalls.append("register")
                if let loginError { throw loginError }
                loginStatus = .requiresApproval
            },
            unregister: { [unowned self] in loginCalls.append("unregister"); loginStatus = .notRegistered },
            openSettings: { [unowned self] in loginCalls.append("settings") })
        Updater.isInstallable = false
        Updater.current = "1.0.0"
        Updater.bundleURL = dir.appendingPathComponent("DisplayTweaks.app")
        Updater.notice = { [unowned self] header, _ in notices.append(header) }
        Updater.ask = { [unowned self] version, _ in asks.append(version) }
        Updater.verify = { _ in }
        Updater.relaunch = { [unowned self] in relaunches.append($0) }
        EventLog.url = dir.appendingPathComponent("events.log")
        EventLog.enable()
    }

    var log: String { (try? String(contentsOf: EventLog.url, encoding: .utf8)) ?? "" }

    /// A controller over the fake world; started (the launch batch) unless told otherwise.
    func controller(start: Bool = true) -> HiDPIController {
        let c = HiDPIController(store: DisplayStore())
        if start { c.start() }
        return c
    }

    /// Lets the trampoline's main-queue hops arrive, then runs the debounce on the manual clock.
    func batch() async {
        await settle()
        world.advance(Displays.debounce)
    }
}

/// The displays behind the fake `DisplaySystem` backend: per display a CGS mode table, the native size and the
/// current mode (the public current mode is derived from it), reconfiguration callbacks delivered through the
/// real static trampoline, injectable transaction failures, and a manual clock for `now` and the debounce.
final class FakeDisplayWorld {
    struct Display {
        var id: CGDirectDisplayID
        var uuid: String
        var name: String?
        var x = 0
        var current: Displays.Mode
        var table = SelfTest.dellTable
        var native: Displays.Size? = SelfTest.dellNative
        /// Overrides the reported refresh rate (0 = not settled).
        var refresh: Double?
        var isBuiltIn = false
        var isActive = true

        func entry(main: CGDirectDisplayID?) -> Displays.Entry {
            SelfTest.entry(uuid, id: id, name: name, x: x, current: current, refresh: refresh, table: table,
                           native: native, builtIn: isBuiltIn, main: id == main, active: isActive)
        }
    }

    var displays: [Display] = []
    /// The main display's ID; nil: none listed (a built-in is main).
    var main: CGDirectDisplayID?
    var now = 100.0
    private var timers: [(at: Double, work: () -> Void)] = []
    /// Every transaction as "<display id>:<mode number>", in order.
    var switches: [String] = []
    /// Injected transaction failure (DD-1: the completion result).
    var error = CGError.success
    /// The transaction completes without error but the mode doesn't change.
    var ignoresSwitch = false
    var registrations = 0
    /// Whether the enable/disable function resolved (Disable Display offered).
    var canDisable = true
    /// Every enable or disable as "<display id>:on" / "<display id>:off", in order.
    var enables: [String] = []
    /// A disabled display stays online but inactive, instead of leaving the list.
    var disabledStaysOnline = false
    private var parked: [Display] = []

    static func dell(_ id: CGDirectDisplayID, _ name: String, x: Int, on: Bool = false, hz: Int = 144) -> Display {
        let current = SelfTest.dellTable.first { $0.width == 2560 && $0.density == (on ? 2 : 1) && $0.refresh == hz }!
        return Display(id: id, uuid: "\(name)-UUID", name: name, x: x, current: current)
    }

    /// A 3840×2160 panel (`SelfTest.uhdTable`, ADR 6a89a88d): On is 3360×1890 at 2× (mode 148), Off its 1× twin (149).
    static func uhd(_ id: CGDirectDisplayID, _ name: String, x: Int, on: Bool = false) -> Display {
        let current = SelfTest.uhdTable.first { $0.number == (on ? 148 : 149) }!
        return Display(id: id, uuid: "\(name)-UUID", name: name, x: x, current: current, table: SelfTest.uhdTable,
                       native: SelfTest.uhdNative)
    }

    /// Not available: no density-2 mode at all (R-2, ADR 6a89a88d).
    static func ipad(_ id: CGDirectDisplayID, x: Int) -> Display {
        Display(id: id, uuid: "IPAD-UUID", name: "iPad", x: x, current: SelfTest.mode(1, 0, 1920, 1080, 1, 60),
                table: [SelfTest.mode(1, 0, 1920, 1080, 1, 60), SelfTest.mode(2, 0, 960, 540, 1, 60)],
                native: Displays.Size(width: 1920, height: 1080))
    }

    func backend(available: @escaping () -> Bool) -> DisplaySystem.Backend {
        .init(isAvailable: available,
              snapshot: { [unowned self] in displays.map { $0.entry(main: main) } },
              configure: { [unowned self] in configure($0, $1) },
              register: { [unowned self] in registrations += 1 },
              now: { [unowned self] in now },
              after: { [unowned self] delay, work in timers.append((now + delay, work)) },
              canDisable: { [unowned self] in canDisable },
              setEnabled: { [unowned self] in setEnabled($0, $1) })
    }

    /// One enable or disable transaction, then its callback. An enabled display comes back at native 1× (macOS
    /// dropping HiDPI), so the re-apply has something to do.
    private func setEnabled(_ id: CGDirectDisplayID, _ on: Bool) -> CGError {
        enables.append("\(id):\(on ? "on" : "off")")
        guard error == .success else { return error }
        if on, let i = parked.firstIndex(where: { $0.id == id }) { displays.append(parked.remove(at: i)) }
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return .success }
        if on {
            displays[i].isActive = true
            displays[i].current = SelfTest.native144
        } else if disabledStaysOnline {
            displays[i].isActive = false
        } else {
            parked.append(displays.remove(at: i))
        }
        deliver(id, on ? .enabledFlag : .disabledFlag)
        return .success
    }

    /// One transaction: takes 1 s, then WindowServer's callbacks (begin, then set-mode) arrive.
    private func configure(_ id: CGDirectDisplayID, _ number: Int32) -> CGError {
        switches.append("\(id):\(number)")
        now += 1
        guard error == .success else { return error }
        if !ignoresSwitch, let i = displays.firstIndex(where: { $0.id == id }),
           let mode = displays[i].table.first(where: { $0.number == number }) {
            displays[i].current = mode
        }
        deliver(id, .beginConfigurationFlag)
        deliver(id, .setModeFlag)
        return .success
    }

    func deliver(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) { DisplaySystem.trampoline(id, flags) }

    /// A mode change made elsewhere (System Settings, macOS restoring a mode).
    func setMode(_ id: CGDirectDisplayID, _ mode: Displays.Mode) {
        displays[displays.firstIndex { $0.id == id }!].current = mode
        deliver(id, .setModeFlag)
    }

    /// The main display changed elsewhere (System Settings → Arrangement): a set-main callback, re-snapshot only.
    func setMain(_ id: CGDirectDisplayID) {
        main = id
        deliver(id, .setMainFlag)
    }

    func unplug(_ id: CGDirectDisplayID) {
        displays.removeAll { $0.id == id }
        deliver(id, .removeFlag)
    }

    func plug(_ d: Display) {
        displays.append(d)
        deliver(d.id, .addFlag)
    }

    /// Moves the manual clock and runs every one-shot that came due, in order.
    func advance(_ seconds: Double) {
        now += seconds
        let due = timers.filter { $0.at <= now }
        timers.removeAll { $0.at <= now }
        due.forEach { $0.work() }
    }
}

/// NSMenu can't be drawn offscreen (it renders only while tracking on a real display), so menus are compared as
/// text: ✓ for on, then 4 spaces per indentation level, the title, a display header's " — status ▸/▾", (disabled);
/// separators as ---; submenus indented before the checkmark column.
@MainActor
func outline(_ menu: NSMenu, _ indent: String = "") -> String {
    menu.items.map { item in
        if item.isSeparatorItem { return indent + "---" }
        // The debug header carries the host bundle's version, which isn't ours under swift test.
        let title = item.title.hasPrefix("DisplayTweaks Dev ") ? "DisplayTweaks Dev <version> (debug)" : item.title
        // A display header adds its status, then ▸ shut / ▾ open when it has options.
        let header = (item.view as? DisplayRowView).map { " — \($0.row.status)" + ($0.isOpenable ? ($0.isOpen ? " ▾" : " ▸") : "") } ?? ""
        let line = indent + (item.state == .on ? "✓ " : "  ") + String(repeating: "    ", count: item.indentationLevel)
            + title + header + (item.isEnabled ? "" : " (disabled)")
        return item.submenu.map { line + "\n" + outline($0, indent + "    ") } ?? line
    }.joined(separator: "\n")
}
