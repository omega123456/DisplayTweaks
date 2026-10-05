import AppKit

/// Carries out the `Displays` decisions and owns the runtime state (Architecture → HiDPIController). Main thread
/// only, event-driven (DD-4): the reconfiguration callback and wake restart a 0.5 s debounce, launch is one batch
/// with every display added. Switches are synchronous, one after another in list order (DD-7).
final class HiDPIController {
    let store: DisplayStore
    /// Called when the status icon may have changed.
    var onChange: () -> Void = {}

    /// The listed displays of the latest snapshot, in list order (R-1), without the ones DisplayTweaks disabled.
    private(set) var displays: [Displays.Entry] = []
    /// Records of the displays DisplayTweaks disabled, by UUID (ADR 2132bdb2).
    private var disabled: [String: DisplayRecord] = [:]
    /// Active displays in the latest snapshot, built-in included: the last-active-display guard.
    private var activeCount = 0
    /// Failed turn-ons (R-10), and failed enables of a disabled display.
    private var failures: [String: Displays.Failure] = [:]
    /// DD-6, per UUID: when DisplayTweaks' last transaction completed, and when the display was last added or woken.
    private var switchedAt: [String: Double] = [:]
    private var addedAt: [String: Double] = [:]
    /// The pending batch: flags per display ID (resolved to UUIDs at snapshot time), flags for every display
    /// (wake), and the arrival of its first callback (DD-6).
    private var pending: [CGDirectDisplayID: Displays.Flags] = [:]
    private var pendingAll: Displays.Flags = []
    private var batchStart: Double?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    init(store: DisplayStore) { self.store = store }

    // MARK: Read-only view for MenuBar

    var isAvailable: Bool { DisplaySystem.isAvailable }
    var rows: [Displays.Row] {
        guard isAvailable else { return [] }
        return Displays.rows(displays, failures: failures, disabled: disabled,
                             activeCount: DisplaySystem.backend.canDisable() ? activeCount : nil)
    }
    var icon: Displays.Icon { Displays.icon(available: isAvailable, rows.map(\.state)) }

    // MARK: Events (DD-4)

    /// Registers the events, then runs the launch batch. Nothing at all when the functions are missing (R-11).
    func start() {
        guard isAvailable else { return }
        DisplaySystem.handler = { [weak self] id, flags in self?.received(id, flags) }
        DisplaySystem.backend.register()
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(Env.workspace.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.woke()
            })
        }
        disabled = store.disabled()
        pendingAll = .added
        runBatch(start: DisplaySystem.backend.now(), launch: true)
    }

    private func received(_ id: CGDirectDisplayID, _ flags: Displays.Flags) {
        pending[id, default: []].formUnion(flags)
        restartDebounce()
    }

    /// System or display wake: every display counts as added in the pending batch.
    private func woke() {
        pendingAll.insert(.added)
        restartDebounce()
    }

    private func restartDebounce() {
        if batchStart == nil { batchStart = DisplaySystem.backend.now() }
        generation += 1
        let current = generation
        DisplaySystem.backend.after(Displays.debounce) { [weak self] in
            guard let self, current == generation, let start = batchStart else { return } // superseded by a later callback
            runBatch(start: start)
        }
    }

    private func runBatch(start: Double, launch: Bool = false) {
        let byID = pending, all = pendingAll
        pending = [:]
        pendingAll = []
        batchStart = nil
        let previous = Dictionary(rows.map { ($0.uuid, $0.state) }, uniquingKeysWith: { a, _ in a })
        let snapshot = read()
        // DD-4: displays absent from the snapshot leave the cache; disabled ones keep their failed enable.
        let present = Set(snapshot.map(\.uuid)).union(disabled.keys)
        failures = failures.filter { present.contains($0.key) }
        switchedAt = switchedAt.filter { present.contains($0.key) }
        addedAt = addedAt.filter { present.contains($0.key) }
        displays = snapshot

        var recheck: [CGDirectDisplayID] = []
        for e in snapshot {
            let flags = all.union(byID[e.id] ?? [])
            if flags.contains(.added) { addedAt[e.uuid] = start }
            if launch {
                EventLog.write("display \(label(e)): state=\(Displays.state(e, failure: nil)) "
                               + "eligible=\(Displays.isEligible(e) ? "yes" : "no") current=\(describe(e))")
            }
            let record = remembered(e)
            let decision = Displays.decide(
                previous: previous[e.uuid], entry: e, remembered: record.choice, flags: flags,
                inGrace: Displays.isInside(since: addedAt[e.uuid], span: Displays.settleGrace, at: start),
                inWindow: Displays.isInside(since: switchedAt[e.uuid], span: Displays.ownSwitchWindow, at: start))
            EventLog.write("event \(label(e)): flags=\(flags) decision=\(decision.rawValue)")
            if !Displays.keepsFailure(e, after: decision) { failures[e.uuid] = nil }
            switch decision {
            case .reapply: turnOn(e.uuid, userStarted: false) // once per batch (R-6, R-10)
            case .rememberOn: remember(.on, e)
            case .rememberOff: remember(.off, e)
            case .recheck: recheck.append(e.id)
            case .nothing: break
            }
        }
        // R-4: an unsettled 0 Hz reading is re-checked after one more debounce, without restarting the grace (DD-6).
        for id in recheck { pending[id] = .recheck }
        if !recheck.isEmpty { restartDebounce() }
        onChange()
    }

    // MARK: Actions (R-4, R-5, R-9, R-10)

    /// The menu toggle: On → Off, Off or Failed → On.
    func toggle(_ uuid: String) {
        guard let state = rows.first(where: { $0.uuid == uuid })?.state else { return }
        switch Displays.toggleTarget(state) {
        case .on: turnOn(uuid, userStarted: true)
        case .off: turnOff(uuid)
        case nil: return
        }
        onChange()
    }

    /// R-9: every connected display that is On, a plain loop in list order (DD-7).
    func turnOffAll() {
        let on = rows.filter { $0.state == .on }.map(\.uuid)
        for uuid in on { turnOff(uuid) }
        EventLog.write("turn off all: \(on.count) displays switched")
        onChange()
    }

    private func turnOn(_ uuid: String, userStarted: Bool) {
        guard let e = displays.first(where: { $0.uuid == uuid }) else { return }
        switch Displays.onTarget(e, userStarted: userStarted) {
        case .success(let mode): perform(.on, e, mode)
        case .failure(let failure): fail(.on, e, failure)
        }
    }

    private func turnOff(_ uuid: String) {
        guard let e = displays.first(where: { $0.uuid == uuid }) else { return }
        switch Displays.offTarget(e) {
        case .success(let mode): perform(.off, e, mode)
        case .failure(let failure): fail(.off, e, failure)
        }
    }

    /// One switch, then a re-read (R-4, R-5). A failure leaves the remembered choice as it was.
    private func perform(_ target: DisplayRecord.Choice, _ e: Displays.Entry, _ mode: Displays.Mode) {
        let (result, duration) = DisplaySystem.switchMode(e.id, mode.number)
        switchedAt[e.uuid] = DisplaySystem.backend.now() // DD-6: from completion
        displays = read()
        let after = displays.first { $0.uuid == e.uuid }
        EventLog.write("switch \(label(e)): \(target.rawValue) target \(mode.width)x\(mode.height) density \(mode.density) "
                       + "\(mode.refresh) Hz mode \(mode.number) result=\(result.rawValue) "
                       + "duration=\(String(format: "%.2f", duration)) s now \(after.map(describe) ?? "gone")")
        if let failure = Displays.outcome(target, completed: result == .success, after: after) { return fail(target, e, failure) }
        failures[e.uuid] = nil
        remember(target, e)
    }

    /// Always logged; shown as Failed only when `Displays.showsFailure` says so (R-10).
    private func fail(_ target: DisplayRecord.Choice, _ e: Displays.Entry, _ failure: Displays.Failure) {
        if Displays.showsFailure(for: target) { failures[e.uuid] = failure }
        EventLog.write("failure \(label(e)): \(Displays.reason(failure))")
    }

    // MARK: Disable and enable (ADR 2132bdb2)

    /// Disable Display: never the last active display. Success is a re-read showing it inactive or gone; the
    /// record then keeps its ID for Enable Display. Its callbacks remove it from the next batch (DD-4).
    func disable(_ uuid: String) {
        guard DisplaySystem.backend.canDisable(), Displays.canDisable(activeCount: activeCount),
              let e = displays.first(where: { $0.uuid == uuid }) else { return }
        let result = DisplaySystem.backend.setEnabled(e.id, false)
        let after = DisplaySystem.backend.snapshot().first { $0.uuid == uuid }
        EventLog.write("disable \(label(e)): result=\(result.rawValue) now \(activity(after))")
        if Displays.enabledOutcome(false, completed: result == .success, after: after) {
            var record = remembered(e)
            record.disabledID = e.id
            disabled[uuid] = record
            store.save(record, for: uuid)
            failures[uuid] = nil
            EventLog.write("record \(label(e)): disabled")
        } else {
            EventLog.write("failure \(label(e)): couldn\u{2019}t disable")
        }
        displays = read()
        onChange()
    }

    /// Enable Display. On success the display's added callback starts its settle grace and re-applies the
    /// remembered HiDPI choice (R-6); on failure the row stays, with the reason under Enable Display.
    func enable(_ uuid: String) {
        guard var record = disabled[uuid], let id = record.disabledID else { return }
        let result = DisplaySystem.backend.setEnabled(id, true)
        let after = DisplaySystem.backend.snapshot().first { $0.uuid == uuid }
        let name = "\(record.name) \(uuid.prefix(8))"
        EventLog.write("enable \(name): result=\(result.rawValue) now \(activity(after))")
        if Displays.enabledOutcome(true, completed: result == .success, after: after) {
            record.disabledID = nil
            disabled[uuid] = nil
            failures[uuid] = nil
            store.save(record, for: uuid)
            EventLog.write("record \(name): enabled")
        } else {
            failures[uuid] = .rejected
            EventLog.write("failure \(name): couldn\u{2019}t enable")
        }
        displays = read()
        onChange()
    }

    /// The listed displays of a fresh snapshot, without the disabled ones. A disabled display that shows up
    /// active again (re-enabled by a logout, restart or replug) loses its disabled mark here.
    private func read() -> [Displays.Entry] {
        let all = DisplaySystem.backend.snapshot()
        activeCount = all.filter(\.isActive).count
        for e in all where e.isActive {
            guard var record = disabled.removeValue(forKey: e.uuid) else { continue }
            record.disabledID = nil
            store.save(record, for: e.uuid)
            failures[e.uuid] = nil
            EventLog.write("record \(label(e)): enabled elsewhere")
        }
        return Displays.listed(all).filter { disabled[$0.uuid] == nil }
    }

    // MARK: Records (R-1, R-6)

    /// The stored record; on first sight, the adopted one. The name is rewritten when it changed.
    private func remembered(_ e: Displays.Entry) -> DisplayRecord {
        guard var record = store.record(for: e.uuid) else {
            let record = Displays.adopt(e)
            store.save(record, for: e.uuid)
            EventLog.write("record \(label(e)): adopted \(record.choice.rawValue) at first sight")
            return record
        }
        if record.name != Displays.baseName(e) {
            record.name = Displays.baseName(e)
            store.save(record, for: e.uuid)
        }
        return record
    }

    private func remember(_ choice: DisplayRecord.Choice, _ e: Displays.Entry) {
        store.save(DisplayRecord(choice: choice, name: Displays.baseName(e)), for: e.uuid)
        EventLog.write("record \(label(e)): remember \(choice.rawValue)")
    }

    // MARK: Log text (API Contracts)

    private func label(_ e: Displays.Entry) -> String { "\(Displays.baseName(e)) \(e.uuid.prefix(8))" }

    private func activity(_ e: Displays.Entry?) -> String { e.map { $0.isActive ? "active" : "inactive" } ?? "gone" }

    private func describe(_ e: Displays.Entry) -> String {
        "\(e.points.width)x\(e.points.height) pt \(e.pixels.width)x\(e.pixels.height) px \(Displays.refresh(e, userStarted: false)) Hz"
    }
}
