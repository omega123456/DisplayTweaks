import AppKit
import ServiceManagement

@main
enum DisplayTweaksMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--self-test") { exit(SelfTest.run() ? 0 : 1) } // before any UI (R-17)
        if args.contains("--log-events") { EventLog.enable() } else { EventLog.removeFile() }
        let app = NSApplication.shared // LSUIElement: no Dock icon, no main menu
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// What DisplayTweaks observes and acts on outside itself. Tests substitute fakes (Tests/DisplayTweaksTests) so
/// they never touch the real desktop or defaults; production never changes these.
enum Env {
    static var workspace = NSWorkspace.shared // wake notifications (DD-4)
    static var defaults = UserDefaults.standard
    static var activate: () -> Void = { NSApp.activate() }
    static var terminate: () -> Void = { NSApp.terminate(nil) }
}

/// `--log-events`: millisecond-timestamped plain-text lines in ~/Library/Logs/DisplayTweaks/events.log
/// (DisplayTweaks Dev: ~/Library/Logs/DisplayTweaks Dev/events.log), cleared at each launch. The file only exists
/// while the flag is used (R-17).
enum EventLog {
    private static var handle: FileHandle?
    #if DEBUG
    private static let folder = "DisplayTweaks Dev"
    #else
    private static let folder = "DisplayTweaks"
    #endif
    static var url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(folder)/events.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func enable() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil) // truncates
        handle = try? FileHandle(forWritingTo: url)
    }

    static func removeFile() { try? FileManager.default.removeItem(at: url) }

    static func write(_ line: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data("\(formatter.string(from: Date())) \(line())\n".utf8))
    }
}

/// Launch at Login via SMAppService.mainApp; the status is always read live, never mirrored (R-15).
enum LaunchAtLogin {
    /// The login-item calls. Tests replace them so xctest is never registered as a login item.
    struct Service {
        var status: () -> SMAppService.Status = { SMAppService.mainApp.status }
        var register: () throws -> Void = { try SMAppService.mainApp.register() }
        var unregister: () throws -> Void = { try SMAppService.mainApp.unregister() }
        var openSettings: () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    }
    static var service = Service()

    static var isEnabled: Bool { service.status() == .enabled }

    /// Enabled → unregister. Requires approval → open Login Items. Otherwise → register
    /// (and open Login Items if the system then asks for approval).
    static func toggle() {
        do {
            switch service.status() {
            case .enabled: try service.unregister()
            case .requiresApproval: service.openSettings()
            default:
                try service.register()
                if service.status() == .requiresApproval { service.openSettings() }
            }
        } catch {
            EventLog.write("launch at login failed: \(error)")
        }
        EventLog.write("launch at login status=\(service.status().rawValue)")
    }
}

/// Wiring. No Accessibility trust gating: DisplayTweaks needs no Accessibility permission.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: DisplayStore!
    private(set) var controller: HiDPIController!
    private(set) var menuBar: MenuBar!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Startup line (API Contracts); the launch batch adds one line per display.
        EventLog.write("DisplayTweaks started pid=\(getpid()) private functions \(DisplaySystem.isAvailable ? "available" : "unavailable")")
        store = DisplayStore()
        controller = HiDPIController(store: store)
        menuBar = MenuBar(controller: controller)
        controller.start()
        Updater.start()
    }
}
