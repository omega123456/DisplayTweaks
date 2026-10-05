import Foundation

/// `--self-test` (R-17, NFR-7): checks of pure logic with explicit failure counting (not `assert`,
/// which is compiled out of release builds). Returns false if any check failed.
enum SelfTest {
    private static var total = 0
    private static var failures: [String] = []

    private static func check(_ name: String, _ ok: Bool) {
        total += 1
        if !ok { failures.append(name) }
    }

    static func run() -> Bool {
        total = 0
        failures = []
        let groups: [(String, () -> Void)] = [
            ("updater", updateVersions),
            ("plausibility", plausibility),
            ("eligibility", eligibility),
            ("current state", currentState),
            ("mode choice", modeChoice),
            ("event decision", eventDecision),
            ("first-sight adoption", adoption),
            ("names and order", namesAndOrder),
            ("menu copy", menuCopy),
            ("icon state", iconState),
        ]
        for (name, group) in groups {
            let before = total
            group()
            print("\(name): \(total - before) checks")
        }
        for f in failures { print("FAIL: \(f)") }
        print("self-test: \(total - failures.count)/\(total) checks passed")
        return failures.isEmpty
    }

    // MARK: Fixtures (also used by the tests' FakeDisplayWorld)

    typealias Mode = Displays.Mode

    static func mode(_ number: Int32, _ flags: UInt32, _ w: Int, _ h: Int, _ density: Float, _ hz: Int) -> Mode {
        Mode(number: number, flags: flags, width: w, height: h, density: density, refresh: hz)
    }

    /// A 2560×1440 Dell's table, shaped like the 2026-10-05 probe. Mode numbers differ from the indexes.
    static let dellTable: [Mode] = [
        mode(10, 0x00000001, 1920, 1080, 1, 144),
        mode(11, 0x00200001, 1280, 720, 2, 144),  // half-size HiDPI: not native
        mode(77, 0x02000001, 2560, 1440, 1, 144),
        mode(78, 0x02000007, 2560, 1440, 1, 144), // the default native mode
        mode(79, 0x02000007, 2560, 1440, 1, 120),
        mode(80, 0x02000001, 2560, 1440, 1, 100), // no HiDPI mode at 100 Hz
        mode(81, 0x02000007, 2560, 1440, 1, 60),
        mode(113, 0x00200001, 2560, 1440, 2, 144),
        mode(114, 0x00200001, 2560, 1440, 2, 144), // byte-identical duplicate
        mode(115, 0x00200001, 2560, 1440, 2, 120),
        mode(116, 0x00200001, 2560, 1440, 2, 120),
        mode(117, 0x00200001, 2560, 1440, 2, 60),
    ]
    static let dellNative = Displays.Size(width: 2560, height: 1440)

    /// A snapshot entry whose current mode is `current` (points = its size, pixels = size × density).
    static func entry(_ uuid: String = "A", id: UInt32 = 1, name: String? = "DELL", x: Int = 0, y: Int = 0,
                      current: Mode, refresh: Double? = nil, table: [Mode] = dellTable,
                      native: Displays.Size? = dellNative, builtIn: Bool = false, main: Bool = false) -> Displays.Entry {
        Displays.Entry(id: id, uuid: uuid, name: name, isBuiltIn: builtIn, isMain: main, origin: CGPoint(x: x, y: y),
                       points: Displays.Size(width: current.width, height: current.height),
                       pixels: Displays.Size(width: Int(Float(current.width) * current.density),
                                             height: Int(Float(current.height) * current.density)),
                       refresh: refresh ?? Double(current.refresh), native: native, modes: table)
    }

    static let hiDPI144 = mode(113, 0, 2560, 1440, 2, 144)
    static let native144 = mode(78, 0, 2560, 1440, 1, 144)
    static let other144 = mode(10, 0, 1920, 1080, 1, 144)

    // MARK: Updater

    private static func updateVersions() {
        check("update: 1.0.10 is newer than 1.0.9", Updater.isNewer("1.0.10", than: "1.0.9"))
        check("update: v-prefixed tag is newer", Updater.isNewer("v1.1.0", than: "1.0.0"))
        check("update: 1.0 equals 1.0.0", !Updater.isNewer("1.0", than: "1.0.0") && !Updater.isNewer("1.0.0", than: "1.0"))
        check("update: older is not newer", !Updater.isNewer("1.9.9", than: "2.0.0"))
    }

    // MARK: Plausibility (NFR-4, DD-2)

    private static func plausibility() {
        let valid = mode(113, 0, 2560, 1440, 2, 144)
        check("plausible: a valid entry", Displays.isPlausible(valid))
        var m = valid; m.width = 0
        check("plausible: width 0 is not", !Displays.isPlausible(m))
        m = valid; m.width = 20000
        check("plausible: width 20000 is not", !Displays.isPlausible(m))
        m = valid; m.density = 0
        check("plausible: density 0 is not", !Displays.isPlausible(m))
        m = valid; m.density = 9
        check("plausible: density 9 is not", !Displays.isPlausible(m))
        m = valid; m.refresh = 5000
        check("plausible: refresh 5000 is not", !Displays.isPlausible(m))
        let zero = Displays.mode(descriptor: [UInt8](repeating: 0, count: Displays.descriptorLength))
        check("plausible: an all-zero descriptor is not", !Displays.isPlausible(zero))

        // DD-2 layout: number @0, flags @4, width @8, height @12, refresh @0xBE, density @0xD0.
        var bytes = [UInt8](repeating: 0, count: Displays.descriptorLength)
        func put<T>(_ value: T, at offset: Int) { withUnsafeBytes(of: value) { bytes.replaceSubrange(offset..<offset + $0.count, with: $0) } }
        put(Int32(113), at: 0); put(UInt32(0x00200001), at: 4); put(UInt32(2560), at: 8); put(UInt32(1440), at: 12)
        put(UInt16(144), at: 0xBE); put(Float32(2), at: 0xD0)
        check("descriptor: fields at their offsets",
              Displays.mode(descriptor: bytes) == mode(113, 0x00200001, 2560, 1440, 2, 144))
    }

    // MARK: Eligibility (R-2)

    private static func eligibility() {
        check("eligible: native density 2 in the table", Displays.isEligible(entry(current: native144)))
        let halfOnly = dellTable.filter { !($0.density == 2 && $0.width == 2560) }
        check("eligible: only half-size density 2 is not", !Displays.isEligible(entry(current: native144, table: halfOnly)))
        check("eligible: an empty table is not", !Displays.isEligible(entry(current: native144, table: [])))
        check("eligible: no native mode is not", !Displays.isEligible(entry(current: native144, native: nil)))
    }

    // MARK: Current state (R-3)

    private static func currentState() {
        check("state: 2× pixels → On", Displays.isOn(entry(current: hiDPI144)))
        check("state: 1× → Off", !Displays.isOn(entry(current: native144)))
        check("state: a non-native size → Off", !Displays.isOn(entry(current: other144)))
        check("state: 1× native is native 1×", Displays.isNative1x(entry(current: native144)))
        check("state: another size is not native 1×", !Displays.isNative1x(entry(current: other144)))
        check("state: Failed shows until cleared", Displays.state(entry(current: native144), failure: .rejected) == .failed(.rejected))
        check("state: Not available beats Failed",
              Displays.state(entry(current: native144, table: []), failure: .rejected) == .notAvailable)
        check("state: On", Displays.state(entry(current: hiDPI144), failure: nil) == .on)
    }

    // MARK: Mode choice (R-4, R-5, DD-2)

    private static func modeChoice() {
        let off = entry(current: native144)
        check("choice: 144 Hz → the first of the identical pair", Displays.hiDPIMode(off, refresh: 144)?.number == 113)
        check("choice: 100 Hz → none", Displays.hiDPIMode(off, refresh: 100) == nil)
        let zero = entry(current: native144, refresh: 0)
        check("choice: a user switch at 0 Hz is treated as 60", Displays.refresh(zero, userStarted: true) == 60
              && Displays.hiDPIMode(zero, refresh: Displays.refresh(zero, userStarted: true))?.number == 117)
        check("choice: an automatic re-apply keeps 0 Hz", Displays.refresh(zero, userStarted: false) == 0)
        check("choice: 143.9 Hz rounds to 144", Displays.refresh(entry(current: native144, refresh: 143.9), userStarted: true) == 144)
        check("choice: Off at 144 → the default-bit entry (78, not 77)", Displays.nativeMode(off, refresh: 144)?.number == 78)
        check("choice: Off at 100 → the only entry at that rate", Displays.nativeMode(off, refresh: 100)?.number == 80)
        let at75 = entry(current: mode(118, 0, 2560, 1440, 2, 75), table: dellTable + [mode(118, 0x00200001, 2560, 1440, 2, 75)])
        check("choice: Off with no density-1 entry at the rate → the default-bit native entry",
              Displays.nativeMode(at75, refresh: 75)?.number == 78)
        check("choice: Off with no default-bit native entry at all → none",
              Displays.nativeMode(entry(current: hiDPI144, table: [hiDPI144]), refresh: 144) == nil)
        check("choice: turn-on at 144 Hz → mode 113; at 100 Hz → no mode at 100",
              (try? Displays.onTarget(off, userStarted: true).get())?.number == 113
              && Displays.onTarget(entry(current: native144, refresh: 100), userStarted: false) == .failure(.noMode(100)))
        check("choice: turn-on at 0 Hz → 60 when user-started, no mode at 0 when automatic",
              (try? Displays.onTarget(zero, userStarted: true).get())?.number == 117
              && Displays.onTarget(zero, userStarted: false) == .failure(.noMode(0)))
        check("choice: Turn Off at 0 Hz keeps 0 → the default-bit native entry (78, not 81 at 60 Hz)",
              (try? Displays.offTarget(entry(current: hiDPI144, refresh: 0)).get())?.number == 78)
        check("choice: Turn Off with no density-1 native mode at all → rejected",
              Displays.offTarget(entry(current: hiDPI144, table: [hiDPI144])) == .failure(.rejected))
        // The mode number is the descriptor field: index 0 here holds mode 500.
        let renumbered = entry(current: native144, table: [mode(500, 0, 2560, 1440, 2, 144), mode(7, 4, 2560, 1440, 1, 144)])
        check("choice: the mode number comes from the descriptor, not the index",
              Displays.hiDPIMode(renumbered, refresh: 144)?.number == 500 && Displays.nativeMode(renumbered, refresh: 144)?.number == 7)

        check("outcome: On completed and re-read On → success", Displays.outcome(.on, completed: true, after: entry(current: hiDPI144)) == nil)
        check("outcome: On completed but not On → rejected", Displays.outcome(.on, completed: true, after: off) == .rejected)
        check("outcome: On, display gone → rejected", Displays.outcome(.on, completed: true, after: nil) == .rejected)
        check("outcome: a transaction error → rejected", Displays.outcome(.off, completed: false, after: off) == .rejected)
        check("outcome: Off completed → success", Displays.outcome(.off, completed: true, after: off) == nil)
        check("outcome: Off completed but still On → rejected",
              Displays.outcome(.off, completed: true, after: entry(current: hiDPI144)) == .rejected)
        check("outcome: Off, display gone → success", Displays.outcome(.off, completed: true, after: nil) == nil)
        check("failure: a failed turn-on shows as Failed", Displays.showsFailure(for: .on))
        check("failure: a failed Off is only logged, never Failed", !Displays.showsFailure(for: .off))
        check("toggle: On → Off", Displays.toggleTarget(.on) == .off)
        check("toggle: Off → On", Displays.toggleTarget(.off) == .on)
        check("toggle: Failed → retry On", Displays.toggleTarget(.failed(.noMode(100))) == .on)
        check("toggle: Not available → nothing", Displays.toggleTarget(.notAvailable) == nil)
    }

    // MARK: Event decision (R-6, R-7, R-10, DD-4, DD-6)

    private static func eventDecision() {
        typealias D = Displays.Decision
        func decide(_ e: Displays.Entry, _ remembered: DisplayRecord.Choice, _ flags: Displays.Flags,
                    previous: Displays.State? = .on, grace: Bool = false, window: Bool = false) -> D {
            Displays.decide(previous: previous, entry: e, remembered: remembered, flags: flags, inGrace: grace, inWindow: window)
        }
        let on = entry(current: hiDPI144), native = entry(current: native144), other = entry(current: other144)

        check("event: added + remembered On + native 1× → re-apply", decide(native, .on, .added) == .reapply)
        check("event: added + remembered On + On → nothing", decide(on, .on, .added) == .nothing)
        check("event: added + remembered On + another non-HiDPI mode → remember Off", decide(other, .on, .added) == .rememberOff)
        check("event: added + remembered On + refresh 0 → re-check after one more debounce",
              decide(entry(current: native144, refresh: 0), .on, .added) == .recheck)
        check("event: the re-check still at 0 Hz → nothing",
              decide(entry(current: native144, refresh: 0), .on, .recheck) == .nothing)
        check("event: the re-check settled at native 1× → re-apply", decide(native, .on, .recheck) == .reapply)
        check("event: added + remembered On + another non-HiDPI mode at 0 Hz → remember Off",
              decide(entry(current: other144, refresh: 0), .on, .added) == .rememberOff)
        check("event: added + remembered Off + On → remember On", decide(on, .off, .added) == .rememberOn)
        check("event: mode changed, left HiDPI, outside grace and window → remember Off", decide(native, .on, .modeChanged) == .rememberOff)
        check("event: the same inside the own-switch window → nothing", decide(native, .on, .modeChanged, window: true) == .nothing)
        check("event: the same inside the 10 s settle grace → nothing", decide(native, .on, .modeChanged, grace: true) == .nothing)
        // DD-6 windows are per display: A switched at t=10, B never; the batch's first callback at t=11.
        let switchedAt = ["A": 10.0]
        let inside = { (uuid: String) in Displays.isInside(since: switchedAt[uuid], span: Displays.ownSwitchWindow, at: 11) }
        check("event: a window on display A doesn't cover display B",
              decide(native, .on, .modeChanged, window: inside("A")) == .nothing
              && decide(entry("B", current: native144), .on, .modeChanged, window: inside("B")) == .rememberOff)
        check("event: the window ends after 2 s", !Displays.isInside(since: 10, span: Displays.ownSwitchWindow, at: 12)
              && Displays.isInside(since: 10, span: Displays.ownSwitchWindow, at: 11.99))
        check("event: grace lasts 10 s", Displays.isInside(since: 0, span: Displays.settleGrace, at: 9.9)
              && !Displays.isInside(since: 0, span: Displays.settleGrace, at: 10))
        check("event: a switch completing after the batch began counts as inside",
              Displays.isInside(since: 12, span: Displays.ownSwitchWindow, at: 11))
        check("event: mode changed into HiDPI made elsewhere → remember On", decide(on, .off, .modeChanged, previous: .off) == .rememberOn)
        check("event: mode changed from one 1× mode to another → nothing",
              decide(native, .off, .modeChanged, previous: .off) == .nothing && decide(native, .on, .modeChanged, previous: .off) == .nothing)
        check("event: mode changed from On to On at another rate → nothing",
              decide(entry(current: mode(115, 0, 2560, 1440, 2, 120)), .on, .modeChanged) == .nothing)
        check("event: added merged with mode changed → treated as added", decide(native, .on, [.added, .modeChanged]) == .reapply)
        check("event: added + removed with the display present → treated as added", decide(native, .on, [.added, .removed]) == .reapply)
        check("event: removed (present) → nothing", decide(native, .on, .removed) == .nothing)
        check("event: wake (as added) → re-apply", decide(native, .on, .added, grace: true) == .reapply)
        check("event: Not available → never re-applied", decide(entry(current: native144, table: []), .on, .added) == .nothing)
        check("event: Failed + added → re-apply", decide(native, .on, .added, previous: .failed(.rejected)) == .reapply)
        check("event: Failed + mode changed → nothing", decide(native, .on, .modeChanged, previous: .failed(.rejected)) == .nothing)
        check("event: only re-snapshot flags → nothing", decide(native, .on, []) == .nothing)

        check("failure: kept while not On", Displays.keepsFailure(native, after: .nothing))
        check("failure: cleared when seen On", !Displays.keepsFailure(on, after: .nothing))
        check("failure: cleared by remember Off", !Displays.keepsFailure(other, after: .rememberOff))
        check("flags: description", "\(Displays.Flags([.added, .modeChanged]))" == "added,modeChanged"
              && "\(Displays.Flags())" == "none" && "\(Displays.Flags([.removed, .recheck]))" == "removed,recheck")
    }

    // MARK: First-sight adoption (R-6)

    private static func adoption() {
        check("adopt: an On display → record On", Displays.adopt(entry(current: hiDPI144)) == DisplayRecord(choice: .on, name: "DELL"))
        check("adopt: an Off display → record Off", Displays.adopt(entry(current: native144)).choice == .off)
        check("adopt: a display without a screen → External Display",
              Displays.adopt(entry(name: nil, current: native144)).name == "External Display")
    }

    // MARK: Names and order (R-1)

    private static func namesAndOrder() {
        let right = entry("R", name: "DELL", x: 2560, current: native144)
        let left = entry("L", name: "DELL", x: 0, current: native144)
        let above = entry("U", name: "LG", x: 0, y: -1440, current: native144)
        let builtIn = entry("B", name: "Built-in", x: -1000, current: native144, builtIn: true)
        let follower = entry("F", name: nil, x: 5120, current: native144)
        let listed = Displays.listed([right, left, builtIn, follower, above])
        check("order: left to right, then top to bottom; built-in omitted", listed.map(\.uuid) == ["U", "L", "R", "F"])
        check("names: duplicates numbered in list order; no screen → External Display",
              Displays.names(listed) == ["LG", "DELL 1", "DELL 2", "External Display"])
        let main = entry("M", name: "DELL S2725DSM", current: native144, main: true)
        check("names: the main display gets (Main)",
              Displays.names([main, entry("D", name: "DELL S2725DC", x: 2560, current: native144)])
                == ["DELL S2725DSM (Main)", "DELL S2725DC"])
        check("names: a numbered duplicate gets the number, then (Main)",
              Displays.names([left, entry("R", name: "DELL", x: 2560, current: native144, main: true)]) == ["DELL 1", "DELL 2 (Main)"])
        check("names: the record and the log keep the name without (Main)",
              Displays.adopt(main).name == "DELL S2725DSM" && Displays.baseName(main) == "DELL S2725DSM")
    }

    // MARK: Menu copy (wireframes)

    private static func menuCopy() {
        let on = entry(current: hiDPI144), off = entry(current: native144)
        check("copy: Off", Displays.info(.off, off) == "Off")
        check("copy: On", Displays.info(.on, on) == "Looks like 2560 × 1440 (5120 × 2880 backing) · 144 Hz")
        check("copy: Failed, no mode", Displays.info(.failed(.noMode(120)), off) == "Failed — no HiDPI mode at 120 Hz. Choose HiDPI to retry.")
        check("copy: Failed, rejected", Displays.info(.failed(.rejected), off) == "Failed — macOS rejected the change. Choose HiDPI to retry.")
        check("copy: Not available", Displays.info(.notAvailable, off) == "HiDPI not available")
        check("copy: unavailable, with U+2019", Displays.unavailableTitle == "HiDPI Unavailable"
              && Displays.unavailableInfo == "This version of macOS doesn\u{2019}t support it.")
        check("copy: empty", Displays.emptyTitle == "No External Display Connected"
              && Displays.emptyInfo == "HiDPI is available for external displays.")
        check("copy: Turn Off All", Displays.turnOffAllTitle == "Turn Off HiDPI on All Displays")
        let rows = Displays.rows([on, entry("B", current: native144, table: [])], failures: ["A": .rejected])
        check("rows: title, state and enabling", rows.map(\.title) == ["DELL 1 — HiDPI", "DELL 2 — HiDPI"]
              && rows[0].state == .failed(.rejected) && rows[0].isEnabled && !rows[1].isEnabled)
        check("turn off all: enabled only with a display On", Displays.canTurnOffAll(Displays.rows([on], failures: [:]))
              && !Displays.canTurnOffAll(rows))
    }

    // MARK: Icon state (R-14)

    private static func iconState() {
        check("icon: normal", Displays.icon(available: true, [.off]) == .normal && Displays.Icon.normal.description == "DisplayTweaks")
        check("icon: normal with On", Displays.icon(available: true, [.off, .on]) == .on
              && Displays.Icon.on.symbol == "display" && Displays.Icon.on.description == "DisplayTweaks, HiDPI on")
        check("icon: any Failed", Displays.icon(available: true, [.on, .failed(.noMode(100))]) == .failed
              && Displays.Icon.failed.symbol == "display.trianglebadge.exclamationmark"
              && Displays.Icon.failed.description == "DisplayTweaks, HiDPI failed")
        check("icon: unavailable", Displays.icon(available: false, []) == .unavailable
              && Displays.Icon.unavailable.symbol == "exclamationmark.triangle"
              && Displays.Icon.unavailable.description == "DisplayTweaks, unavailable")
        check("icon: unavailable beats Failed", Displays.icon(available: false, [.failed(.rejected)]) == .unavailable)
        check("icon: a Not-available display alone → normal", Displays.icon(available: true, [.notAvailable]) == .normal)
    }
}
