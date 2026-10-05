import AppKit
import Testing
@testable import DisplayTweaks

/// Whether any display is online (none in a sandbox or CI); the real snapshot test is skipped then.
private let displayOnline: Bool = {
    var count: UInt32 = 0
    return CGGetOnlineDisplayList(0, nil, &count) == .success && count > 0
}()

/// DD-1 symbol resolution and the read-only snapshot. Nothing here switches a display.
@Suite struct DisplaySystemTests {
    @Test func resolution() {
        // The three names resolve on this macOS; the production default backend reports them available.
        #expect(DisplaySystem.resolve(DisplaySystem.imagePath, DisplaySystem.symbols) != nil)
        #expect(DisplaySystem.Backend().isAvailable())
        // A missing image or any missing symbol means unavailable (R-11).
        #expect(DisplaySystem.resolve("/nonexistent/CoreGraphics", DisplaySystem.symbols) == nil)
        let (a, b, _) = DisplaySystem.symbols
        #expect(DisplaySystem.resolve(DisplaySystem.imagePath, (a, b, "NoSuchFunction")) == nil)
    }

    /// The production snapshot, for real and read-only (NFR-7): every display has a UUID, a current mode and
    /// plausible table entries.
    @MainActor @Test(.enabled(if: displayOnline, "no display online"))
    func realSnapshot() {
        let snapshot = DisplaySystem.Backend().snapshot()
        #expect(!snapshot.isEmpty)
        for e in snapshot {
            #expect(UUID(uuidString: e.uuid) != nil)
            #expect(e.points.width > 0 && e.points.height > 0 && e.pixels.width >= e.points.width)
            #expect(e.modes.allSatisfy(Displays.isPlausible))
            if !e.isBuiltIn { #expect(!e.modes.isEmpty) }
        }
    }
}

extension Desktop {
    /// The callback trampoline and the switch timing: global seams, so inside the serialized suite.
    @MainActor @Suite struct DisplaySystemSeamTests {
        let h = Harness()

        @Test func trampolineFlagMapping() async {
            let cases: [(CGDisplayChangeSummaryFlags, Displays.Flags?)] = [
                (.addFlag, .added), (.enabledFlag, .added),
                (.removeFlag, .removed), (.disabledFlag, .removed),
                (.setModeFlag, .modeChanged),
                ([.addFlag, .setModeFlag], [.added, .modeChanged]),
                ([.addFlag, .removeFlag], [.added, .removed]),
                ([.movedFlag], []), ([.setMainFlag, .desktopShapeChangedFlag], []), // re-snapshot only
                (.beginConfigurationFlag, nil), ([.beginConfigurationFlag, .addFlag], nil), // ignored
            ]
            for (flags, expected) in cases {
                #expect(DisplaySystem.trampoline(7, flags) == expected, "\(flags)")
            }
            // The mapped flags reach the handler on the main thread.
            var received: [Displays.Flags] = []
            DisplaySystem.handler = { id, flags in
                #expect(Thread.isMainThread && id == 7)
                received.append(flags)
            }
            DisplaySystem.trampoline(7, .setModeFlag)
            DisplaySystem.trampoline(7, .beginConfigurationFlag)
            await settle()
            #expect(received.last == .modeChanged)
        }

        @Test func switchModeTimesTheTransaction() {
            h.world.displays = [FakeDisplayWorld.dell(2, "DELL S2725DC", x: 0)]
            let (result, duration) = DisplaySystem.switchMode(2, 113)
            #expect(result == .success && duration == 1 && h.world.switches == ["2:113"])
            h.world.error = .illegalArgument
            #expect(DisplaySystem.switchMode(2, 78).result == .illegalArgument)
        }
    }
}
