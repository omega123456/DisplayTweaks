import AppKit
import CoreGraphics
import IOKit.graphics

/// The system seam: everything DisplayTweaks reads from or does to the display system goes through `backend`,
/// a struct of closures that tests replace (NFR-7). Production never changes it. Closures that change something
/// are one-line system calls; the read-only snapshot is a separate function that one test runs for real.
enum DisplaySystem {
    struct Backend {
        /// R-11: all three private functions resolved.
        var isAvailable: () -> Bool = { functions != nil }
        /// Every online display, read-only.
        var snapshot: () -> [Displays.Entry] = readSnapshot
        /// One permanent configuration transaction selecting a mode number (DD-1, DD-3); the completion result.
        var configure: (CGDirectDisplayID, Int32) -> CGError = transaction
        /// Registers the static trampoline once (DD-4).
        var register: () -> Void = { _ = CGDisplayRegisterReconfigurationCallback({ id, flags, _ in _ = trampoline(id, flags) }, nil) }
        /// The clock for the debounce, the settle grace and the own-switch window (DD-6).
        var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
        /// Runs work once on the main queue after a delay: the debounce (DD-4).
        var after: (Double, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }
        /// The fourth private function resolved: Disable Display is offered (ADR 2132bdb2).
        var canDisable: () -> Bool = { configureEnabled != nil }
        /// One session-scoped transaction enabling or disabling a display; the completion result.
        var setEnabled: (CGDirectDisplayID, Bool) -> CGError = enableTransaction
    }
    static var backend = Backend()

    static var isAvailable: Bool { backend.isAvailable() }

    // MARK: Switch (R-4, R-5, DD-1, DD-3)

    /// One transaction for mode `number` on display `id`: its completion result and duration (NFR-2).
    static func switchMode(_ id: CGDirectDisplayID, _ number: Int32) -> (result: CGError, duration: Double) {
        let start = backend.now()
        let result = backend.configure(id, number)
        return (result, backend.now() - start)
    }

    /// Begin → select the mode with the begin call's token → complete with permanent scope. Never run by tests.
    static func transaction(_ id: CGDirectDisplayID, _ number: Int32) -> CGError {
        var token: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&token)
        guard begun == .success else { return begun }
        functions?.configureMode(token, id, number)
        return CGCompleteDisplayConfiguration(token, .permanently)
    }

    /// Begin → enable or disable with the begin call's token → complete for this login session only, so a logout
    /// or restart always brings the display back (ADR 2132bdb2). Never run by tests.
    static func enableTransaction(_ id: CGDirectDisplayID, _ enabled: Bool) -> CGError {
        var token: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&token)
        guard begun == .success else { return begun }
        configureEnabled?(token, id, enabled)
        return CGCompleteDisplayConfiguration(token, .forSession)
    }

    // MARK: Callback (DD-4)

    /// Receives the mapped flags on the main thread. The controller sets it.
    static var handler: (CGDirectDisplayID, Displays.Flags) -> Void = { _, _ in }

    /// The reconfiguration callback. Begin-configuration callbacks are ignored (nil, the debounce untouched).
    /// add/enabled → added, remove/disabled → removed, set-mode → mode changed; any other flag only re-snapshots
    /// (an empty set), such as set-main, which refreshes the " (Main)" row (R-1). Hops to the main thread; returns the mapping so tests can check it directly.
    @discardableResult
    static func trampoline(_ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags) -> Displays.Flags? {
        if flags.contains(.beginConfigurationFlag) { return nil }
        var mapped: Displays.Flags = []
        if !flags.isDisjoint(with: [.addFlag, .enabledFlag]) { mapped.insert(.added) }
        if !flags.isDisjoint(with: [.removeFlag, .disabledFlag]) { mapped.insert(.removed) }
        if flags.contains(.setModeFlag) { mapped.insert(.modeChanged) }
        DispatchQueue.main.async { handler(id, mapped) }
        return mapped
    }

    // MARK: Snapshot (read-only)

    /// Public CoreGraphics and NSScreen per online display, plus its CGS mode table. Main thread (NSScreen).
    static func readSnapshot() -> [Displays.Entry] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32) // ponytail: 32 displays max
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let screens = NSScreen.screens
        return ids.prefix(Int(count)).compactMap { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), let current = CGDisplayCopyDisplayMode(id)
            else { return nil }
            // R-2: the native size is the public 1× mode flagged native.
            let native = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? [])
                .first { $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 && $0.pixelWidth == $0.width }
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            return Displays.Entry(id: id, uuid: CFUUIDCreateString(nil, uuid) as String, name: screen?.localizedName,
                                  isBuiltIn: CGDisplayIsBuiltin(id) != 0, isMain: CGDisplayIsMain(id) != 0,
                                  isActive: CGDisplayIsActive(id) != 0, origin: CGDisplayBounds(id).origin,
                                  points: Displays.Size(width: current.width, height: current.height),
                                  pixels: Displays.Size(width: current.pixelWidth, height: current.pixelHeight),
                                  refresh: current.refreshRate,
                                  native: native.map { Displays.Size(width: $0.width, height: $0.height) },
                                  modes: modeTable(id))
        }
    }

    /// The CGS mode table (DD-1, DD-2): count initialised to 0, 0-based index, a zeroed 0xDC buffer for every
    /// call; implausible entries skipped (NFR-4).
    static func modeTable(_ id: CGDirectDisplayID) -> [Displays.Mode] {
        guard let functions else { return [] }
        var count: Int32 = 0
        functions.modeCount(id, &count)
        return (0..<max(count, 0)).map { index in
            var buffer = [UInt8](repeating: 0, count: Displays.descriptorLength)
            functions.modeDescription(id, index, &buffer, Int32(buffer.count))
            return Displays.mode(descriptor: buffer)
        }.filter(Displays.isPlausible)
    }

    // MARK: Private functions (DD-1, ADR 50914964, ADR 2132bdb2)

    // The ABI contract of DD-1. All four return nothing.
    /// Mode count: display ID, out-pointer to the count (initialise it to 0).
    typealias ModeCountFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Void
    /// Mode descriptor: display ID, 0-based index, caller buffer (zeroed before each call), buffer length (0xDC).
    typealias ModeDescriptionFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Void
    /// Select mode: the token of the public begin-configuration call (never a connection ID), display ID,
    /// and the descriptor's mode-number field (never the loop index).
    typealias ConfigureModeFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> Void
    /// Enable or disable: the begin call's token, display ID, enabled (ADR 2132bdb2).
    typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Void

    struct Functions {
        let modeCount: ModeCountFn
        let modeDescription: ModeDescriptionFn
        let configureMode: ConfigureModeFn
    }

    static let imagePath = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    static let symbols = ("CGSGetNumberOfDisplayModes", "CGSGetDisplayModeDescriptionOfLength", "CGSConfigureDisplayMode")

    /// Resolved once, at first use; nil when any of the three is missing (R-11, NFR-4).
    static let functions: Functions? = resolve(imagePath, symbols)

    /// Resolved on its own: when it's missing, only Disable Display is left out; HiDPI still works.
    static let enabledSymbol = "CGSConfigureDisplayEnabled"
    static let configureEnabled: ConfigureEnabledFn? = resolveEnabled(imagePath, enabledSymbol)

    static func resolveEnabled(_ path: String, _ name: String) -> ConfigureEnabledFn? {
        guard let image = dlopen(path, RTLD_LAZY), let f = dlsym(image, name) else { return nil }
        return unsafeBitCast(f, to: ConfigureEnabledFn.self)
    }

    /// The three functions from the image at `path`, or nil if the image or any symbol can't be found.
    /// The image handle is deliberately never closed: the functions stay valid for the life of the process.
    static func resolve(_ path: String, _ names: (String, String, String)) -> Functions? {
        guard let image = dlopen(path, RTLD_LAZY),
              let count = dlsym(image, names.0),
              let describe = dlsym(image, names.1),
              let configure = dlsym(image, names.2)
        else { return nil }
        return Functions(modeCount: unsafeBitCast(count, to: ModeCountFn.self),
                         modeDescription: unsafeBitCast(describe, to: ModeDescriptionFn.self),
                         configureMode: unsafeBitCast(configure, to: ConfigureModeFn.self))
    }
}
