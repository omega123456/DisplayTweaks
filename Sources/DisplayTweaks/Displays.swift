import CoreGraphics
import Foundation

// The pure model (NFR-7): value types and `static func`s only, no AppKit, CoreGraphics calls or private calls.
// Every decision lives here so `--self-test` covers it; the controller and the menu only carry decisions out.

/// One display's persisted record (DD-5, ADR e6a117ad), stored as JSON under `display.<UUID>` by `DisplayStore`.
/// Mode numbers and native sizes are never stored (DD-2): modes are matched by attributes on every snapshot.
struct DisplayRecord: Codable, Equatable {
    enum Choice: String, Codable { case on, off }

    static let currentVersion = 1

    /// The remembered HiDPI choice (R-6).
    var choice: Choice
    /// The localized display name, rewritten when it changes (R-1).
    var name: String
    var version = DisplayRecord.currentVersion
}

enum Displays {
    // MARK: Constants

    /// DD-4: one-shot, restarted by each callback.
    static let debounce = 0.5
    /// DD-6: per display, from added or wake.
    static let settleGrace = 10.0
    /// DD-6: per display, from the completion of DisplayTweaks' own transaction.
    static let ownSwitchWindow = 2.0
    /// DD-2: the mode descriptor's length.
    static let descriptorLength = 0xDC
    /// DD-2, R-5: the default-mode bit, used only to pick among density-1 duplicates.
    static let defaultModeFlag: UInt32 = 0x4

    // MARK: Value types (Data Models)

    /// A size in whole points or pixels. Deliberately not the CoreGraphics size type, whose name the private-symbol
    /// grep (AC 3: words starting with "CGS") would report.
    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    /// A WindowServer mode-table entry (DD-2). Width and height are in points; pixels are those times the density.
    struct Mode: Equatable {
        var number: Int32
        var flags: UInt32
        var width: Int
        var height: Int
        var density: Float
        var refresh: Int
    }

    /// One display in a snapshot, read fresh after every event.
    struct Entry: Equatable {
        var id: CGDirectDisplayID
        var uuid: String
        /// The localized screen name; nil for a display without its own screen (a mirror-set follower, R-1).
        var name: String?
        var isBuiltIn: Bool
        /// The main display (owner request overriding part of R-1: its toggle row gets " (Main)").
        var isMain = false
        var origin: CGPoint
        /// The current public mode.
        var points: Size
        var pixels: Size
        var refresh: Double
        /// The size of the public mode flagged native (R-2); nil if none is.
        var native: Size?
        /// The CGS mode table, implausible entries already skipped (NFR-4).
        var modes: [Mode]
    }

    enum Failure: Error, Equatable { case rejected, noMode(Int) }

    /// The per-display runtime state (R-3, R-10, R-2).
    enum State: Equatable { case off, on, failed(Failure), notAvailable }

    /// Reconfiguration flags merged per display over a batch (DD-4). `recheck` marks the one extra debounce after
    /// an unsettled (0 Hz) reading: it decides like `added` but, not being an add, doesn't restart the settle grace (DD-6).
    struct Flags: OptionSet, CustomStringConvertible {
        let rawValue: Int
        static let added = Flags(rawValue: 1)
        static let removed = Flags(rawValue: 2)
        static let modeChanged = Flags(rawValue: 4)
        static let recheck = Flags(rawValue: 8)

        var description: String {
            let names = [(Flags.added, "added"), (.removed, "removed"), (.modeChanged, "modeChanged"), (.recheck, "recheck")]
                .filter { contains($0.0) }.map(\.1)
            return names.isEmpty ? "none" : names.joined(separator: ",")
        }
    }

    /// The event decision for one display (DD-4).
    enum Decision: String { case nothing, reapply, rememberOff, rememberOn, recheck }

    /// One display's two menu rows (DD-8).
    struct Row: Equatable {
        var uuid: String
        var title: String
        var info: String
        var state: State
        var isEnabled: Bool { state != .notAvailable }
    }

    // MARK: Mode table (DD-2, NFR-4)

    /// Reads a 0xDC-byte descriptor: number @0, flags @4, width @8, height @12, refresh (UInt16) @0xBE,
    /// density (Float32) @0xD0. The mode number is this field, never the table index (DD-1).
    static func mode(descriptor d: [UInt8]) -> Mode {
        d.withUnsafeBytes { b in
            Mode(number: b.loadUnaligned(fromByteOffset: 0, as: Int32.self),
                 flags: b.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                 width: Int(b.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                 height: Int(b.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                 density: b.loadUnaligned(fromByteOffset: 0xD0, as: Float32.self),
                 refresh: Int(b.loadUnaligned(fromByteOffset: 0xBE, as: UInt16.self)))
        }
    }

    /// NFR-4: width and height 1…16384, density 0.5…4, refresh at most 1000. An all-zero entry fails.
    static func isPlausible(_ m: Mode) -> Bool {
        (1...16384).contains(m.width) && (1...16384).contains(m.height) && (0.5...4).contains(m.density) && m.refresh <= 1000
    }

    /// Native-size table entries of one density, in table order.
    private static func nativeModes(_ e: Entry, density: Float) -> [Mode] {
        guard let n = e.native else { return [] }
        return e.modes.filter { $0.width == n.width && $0.height == n.height && $0.density == density }
    }

    // MARK: Eligibility and state (R-2, R-3)

    /// R-2: the table holds a native-size density-2 mode.
    static func isEligible(_ e: Entry) -> Bool { !nativeModes(e, density: 2).isEmpty }

    /// R-3: native size in points at twice that in pixels, whoever set it.
    static func isOn(_ e: Entry) -> Bool {
        guard let n = e.native else { return false }
        return e.points == n && e.pixels == Size(width: n.width * 2, height: n.height * 2)
    }

    /// R-6: native size at 1×, the pattern of macOS having dropped HiDPI.
    static func isNative1x(_ e: Entry) -> Bool { e.native != nil && e.points == e.native && e.pixels == e.native }

    /// Not available beats Failed (R-10); a failure shows until cleared (`keepsFailure`).
    static func state(_ e: Entry, failure: Failure?) -> State {
        if !isEligible(e) { return .notAvailable }
        if let failure { return .failed(failure) }
        return isOn(e) ? .on : .off
    }

    // MARK: Mode choice (R-4, R-5)

    /// R-4: the current rate rounded; a user-started switch treats 0 as 60.
    static func refresh(_ e: Entry, userStarted: Bool) -> Int {
        let r = Int(e.refresh.rounded())
        return r == 0 && userStarted ? 60 : r
    }

    /// R-4: native size, density 2, that rate; duplicates are identical, so the first in table order wins.
    static func hiDPIMode(_ e: Entry, refresh: Int) -> Mode? { nativeModes(e, density: 2).first { $0.refresh == refresh } }

    /// R-5: native size, density 1, that rate, preferring the default-mode bit; otherwise the default-bit native
    /// entry at any rate (also when the rate reads 0).
    static func nativeMode(_ e: Entry, refresh: Int) -> Mode? {
        let native = nativeModes(e, density: 1)
        let atRate = native.filter { $0.refresh == refresh }
        let isDefault = { (m: Mode) in m.flags & defaultModeFlag != 0 }
        return atRate.first(where: isDefault) ?? atRate.first ?? native.first(where: isDefault)
    }

    /// R-4: the turn-on mode at the rate (0 → 60 when user-started); none at that rate is `.noMode(rate)` (R-10).
    static func onTarget(_ e: Entry, userStarted: Bool) -> Result<Mode, Failure> {
        let r = refresh(e, userStarted: userStarted)
        return hiDPIMode(e, refresh: r).map { .success($0) } ?? .failure(.noMode(r))
    }

    /// R-5: the Turn Off mode at the raw rounded rate (no 0 → 60: that is for turning on, R-4). No density-1 native
    /// mode at all is a rejection, handled like any failed Off (`showsFailure`).
    static func offTarget(_ e: Entry) -> Result<Mode, Failure> {
        nativeMode(e, refresh: refresh(e, userStarted: false)).map { .success($0) } ?? .failure(.rejected)
    }

    /// The menu toggle (R-4, R-5, R-10): On turns off, Off and Failed turn on (a retry), Not available does nothing.
    static func toggleTarget(_ state: State) -> DisplayRecord.Choice? {
        switch state {
        case .on: return .off
        case .off, .failed: return .on
        case .notAvailable: return nil
        }
    }

    /// R-4, R-5: success is a completed transaction and a re-read showing the target (for Off: not still On).
    static func outcome(_ target: DisplayRecord.Choice, completed: Bool, after: Entry?) -> Failure? {
        guard completed else { return .rejected }
        return (after.map(isOn) == true) == (target == .on) ? nil : .rejected
    }

    /// R-3, R-10: only a failed turn-on shows as Failed. A failed Off is logged, keeps the remembered choice and
    /// leaves the display showing what the re-read says (normally On), so the toggle and Turn Off All still act on it.
    static func showsFailure(for target: DisplayRecord.Choice) -> Bool { target == .on }

    // MARK: Events (R-6, R-7, R-10, DD-4, DD-6)

    /// R-6 first sight: the record adopts the current state.
    static func adopt(_ e: Entry) -> DisplayRecord { DisplayRecord(choice: isOn(e) ? .on : .off, name: baseName(e)) }

    /// DD-6: inside a span that started at `since` (nil: never started), judged at `time`. A start after `time`
    /// (a switch completing after the batch's first callback) counts as inside.
    static func isInside(since: Double?, span: Double, at time: Double) -> Bool { since.map { time - $0 < span } ?? false }

    /// The event decision per display (DD-4). `previous` is the runtime state before this batch (nil if uncached).
    /// Wake and launch arrive as `added`; when the display is present, added wins over removed.
    static func decide(previous: State?, entry e: Entry, remembered: DisplayRecord.Choice, flags: Flags,
                       inGrace: Bool, inWindow: Bool) -> Decision {
        guard isEligible(e) else { return .nothing }                        // R-2: never switched
        if isOn(e) { return remembered == .off ? .rememberOn : .nothing }    // R-6: HiDPI chosen elsewhere is adopted
        guard remembered == .on else { return .nothing }
        if !flags.isDisjoint(with: [.added, .recheck]) {                     // R-6: launch, reconnect, wake
            guard isNative1x(e) else { return .rememberOff }                 // another non-HiDPI mode: the user's pick
            if refresh(e, userStarted: false) == 0 { return flags.contains(.recheck) ? .nothing : .recheck } // R-4
            return .reapply
        }
        let leftHiDPI = flags.contains(.modeChanged) && previous == .on
        return leftHiDPI && !inGrace && !inWindow ? .rememberOff : .nothing  // R-7
    }

    /// R-10: a failure stays until a snapshot shows the display On or an R-6/R-7 decision changes its remembered
    /// choice. (A re-apply replaces it with the switch's own outcome.)
    static func keepsFailure(_ e: Entry, after d: Decision) -> Bool { !isOn(e) && d != .rememberOn && d != .rememberOff }

    // MARK: Names and order (R-1)

    /// Not built-in, left to right by origin, then top to bottom.
    static func listed(_ snapshot: [Entry]) -> [Entry] {
        snapshot.filter { !$0.isBuiltIn }.sorted { ($0.origin.x, $0.origin.y) < ($1.origin.x, $1.origin.y) }
    }

    /// The name stored in the record.
    static func baseName(_ e: Entry) -> String { e.name ?? "External Display" }

    /// Menu names in list order: every duplicate gets " 1", " 2", …, then the main display " (Main)" (owner
    /// request overriding part of R-1, FancyMacZones' convention). Display copy only: the record keeps `baseName`.
    static func names(_ listed: [Entry]) -> [String] {
        let base = listed.map(baseName)
        var seen: [String: Int] = [:]
        return zip(listed, base).map { e, name in
            var out = name
            if base.filter({ $0 == name }).count > 1 {
                seen[name, default: 0] += 1
                out += " \(seen[name]!)"
            }
            return e.isMain ? out + " (Main)" : out
        }
    }

    // MARK: Menu copy (wireframes)

    static let emptyTitle = "No External Display Connected"
    static let emptyInfo = "HiDPI is available for external displays."
    static let unavailableTitle = "HiDPI Unavailable"
    static let unavailableInfo = "This version of macOS doesn\u{2019}t support it."
    static let turnOffAllTitle = "Turn Off HiDPI on All Displays"

    static func reason(_ f: Failure) -> String {
        switch f {
        case .rejected: return "macOS rejected the change"
        case .noMode(let r): return "no HiDPI mode at \(r) Hz"
        }
    }

    /// The info row per state (state/copy table).
    static func info(_ state: State, _ e: Entry) -> String {
        switch state {
        case .off: return "Off"
        case .on:
            return "Looks like \(e.points.width) × \(e.points.height) "
                + "(\(e.pixels.width) × \(e.pixels.height) backing) · \(refresh(e, userStarted: false)) Hz"
        case .failed(let f): return "Failed — \(reason(f)). Choose HiDPI to retry."
        case .notAvailable: return "HiDPI not available"
        }
    }

    static func rows(_ listed: [Entry], failures: [String: Failure]) -> [Row] {
        zip(listed, names(listed)).map { e, name in
            let state = state(e, failure: failures[e.uuid])
            return Row(uuid: e.uuid, title: "\(name) — HiDPI", info: info(state, e), state: state)
        }
    }

    /// R-9: enabled when any connected display is On.
    static func canTurnOffAll(_ rows: [Row]) -> Bool { rows.contains { $0.state == .on } }

    // MARK: Status icon (R-14)

    enum Icon: Equatable {
        case normal, on, failed, unavailable

        var symbol: String {
            switch self {
            case .normal, .on: return "display"
            case .failed: return "display.trianglebadge.exclamationmark"
            case .unavailable: return "exclamationmark.triangle"
            }
        }

        var description: String {
            switch self {
            case .normal: return "DisplayTweaks"
            case .on: return "DisplayTweaks, HiDPI on"
            case .failed: return "DisplayTweaks, HiDPI failed"
            case .unavailable: return "DisplayTweaks, unavailable"
            }
        }
    }

    /// Precedence: unavailable > any Failed > normal (with "HiDPI on" when any display is On).
    static func icon(available: Bool, _ states: [State]) -> Icon {
        if !available { return .unavailable }
        if states.contains(where: { if case .failed = $0 { return true } else { return false } }) { return .failed }
        return states.contains(.on) ? .on : .normal
    }
}
