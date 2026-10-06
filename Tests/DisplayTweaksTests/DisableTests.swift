import AppKit
import Testing
@testable import DisplayTweaks

extension Desktop {
    /// Disable Display and Enable Display (ADR 2132bdb2) over `FakeDisplayWorld`: never a real display.
    @MainActor @Suite struct DisableTests {
        let h = Harness()
        let dsm = "DELL S2725DSM-UUID", dc = "DELL S2725DC-UUID"

        func world(dcOn: Bool = true) {
            h.world.displays = [FakeDisplayWorld.dell(1, "DELL S2725DSM", x: 0, on: true),
                                FakeDisplayWorld.dell(2, "DELL S2725DC", x: 2560, on: dcOn)]
            h.world.main = 1
        }
        func row(_ c: HiDPIController, _ uuid: String) -> Displays.Row? { c.rows.first { $0.uuid == uuid } }
        func record(_ uuid: String) -> DisplayRecord? { DisplayStore().record(for: uuid) }
        /// Event decisions logged for the DC (one at launch).
        var dcEvents: Int { h.log.components(separatedBy: "event DELL S2725DC").count - 1 }

        @Test func disableThenEnableRestoresHiDPI() async {
            world()
            let c = h.controller()
            c.disable(dc)
            #expect(h.world.enables == ["2:off"])
            #expect(record(dc)?.disabledID == 2 && record(dc)?.choice == .on)
            #expect(row(c, dc)?.state == .disabled && row(c, dc)?.status == "Disabled")
            #expect(h.log.contains("disable DELL S2725DC DELL S27: result=0 now gone"))
            #expect(h.log.contains("record DELL S2725DC DELL S27: disabled"))
            // Its callback: the display is gone, so the batch decides nothing for it, and the row stays.
            await h.batch()
            #expect(dcEvents == 1)
            #expect(row(c, dc)?.state == .disabled)
            // Enable: back at native 1×, then the added callback re-applies the remembered HiDPI (R-6).
            c.enable(dc)
            #expect(h.world.enables == ["2:off", "2:on"])
            #expect(record(dc)?.disabledID == nil)
            #expect(h.log.contains("enable DELL S2725DC DELL S27: result=0 now active"))
            #expect(row(c, dc)?.state == .off)
            await h.batch()
            #expect(h.log.contains("event DELL S2725DC DELL S27: flags=added decision=reapply"))
            #expect(h.world.switches == ["2:113"])
            #expect(row(c, dc)?.state == .on)
        }

        @Test func neverTheLastActiveDisplay() {
            h.world.displays = [FakeDisplayWorld.dell(1, "DELL S2725DSM", x: 0, on: true)]
            let c = h.controller()
            c.disable(dsm)
            #expect(h.world.enables.isEmpty)
            #expect(row(c, dsm)?.options.last?.title == Displays.onlyActiveInfo)
            // A built-in counts as active.
            var builtIn = FakeDisplayWorld.dell(9, "Built-in", x: -1512)
            builtIn.isBuiltIn = true
            h.world.plug(builtIn)
            let d = h.controller()
            d.disable(dsm)
            #expect(h.world.enables == ["1:off"])
            #expect(row(d, dsm)?.state == .disabled)
            // Now the built-in is the only active display, and it isn't listed: nothing more to disable.
            #expect(d.rows.count == 1)
        }

        /// ADR 55cd537c: a display without any HiDPI mode is still offered Disable Display, under the same guard.
        @Test func ineligibleDisplay() {
            h.world.displays = [FakeDisplayWorld.ipad(3, x: 0)]
            let c = h.controller()
            #expect(row(c, "IPAD-UUID")?.options.map(\.title) == [Displays.disableTitle, Displays.onlyActiveInfo])
            c.disable("IPAD-UUID")
            #expect(h.world.enables.isEmpty) // the last active display
            world()
            h.world.plug(FakeDisplayWorld.ipad(3, x: 5120))
            let d = h.controller()
            #expect(row(d, "IPAD-UUID")?.state == .notAvailable)
            d.disable("IPAD-UUID")
            #expect(h.world.enables == ["3:off"] && row(d, "IPAD-UUID")?.state == .disabled)
            d.enable("IPAD-UUID")
            #expect(h.world.enables == ["3:off", "3:on"] && row(d, "IPAD-UUID")?.state == .notAvailable)
        }

        @Test func withoutTheFunction() {
            world()
            h.world.canDisable = false
            let c = h.controller()
            c.disable(dc)
            #expect(h.world.enables.isEmpty)
            #expect(row(c, dc)?.options.map(\.title) == ["HiDPI", Displays.info(.on, c.displays[1])])
        }

        @Test func failures() {
            world()
            let c = h.controller()
            h.world.error = .illegalArgument
            c.disable(dc)
            #expect(h.log.contains("failure DELL S2725DC DELL S27: couldn\u{2019}t disable"))
            #expect(record(dc)?.disabledID == nil && row(c, dc)?.state == .on)
            h.world.error = .success
            c.disable(dc)
            h.world.error = .illegalArgument
            c.enable(dc)
            #expect(h.log.contains("failure DELL S2725DC DELL S27: couldn\u{2019}t enable"))
            #expect(row(c, dc)?.state == .disabled && row(c, dc)?.options.last?.title == Displays.enableFailedInfo)
            #expect(record(dc)?.disabledID == 2)
            h.world.error = .success
            c.enable(dc)
            #expect(row(c, dc)?.state == .off && record(dc)?.disabledID == nil)
            c.enable(dc) // not disabled: nothing
            #expect(h.world.enables == ["2:off", "2:off", "2:on", "2:on"])
        }

        /// The record keeps the ID, so a relaunch still offers Enable Display.
        @Test func survivesRelaunch() {
            world()
            h.controller().disable(dc)
            let c = h.controller()
            #expect(row(c, dc)?.state == .disabled && row(c, dc)?.name == "DELL S2725DC")
            c.enable(dc)
            #expect(h.world.enables == ["2:off", "2:on"] && row(c, dc)?.state == .off)
        }

        /// A disabled display macOS keeps listing as inactive: shown as disabled, never decided on, and unmarked when
        /// it comes back active from elsewhere (logout, restart, replug).
        @Test func staysOnlineInactive() async {
            world()
            h.world.disabledStaysOnline = true
            let c = h.controller()
            c.disable(dc)
            #expect(h.log.contains("now inactive") && row(c, dc)?.state == .disabled && c.displays.count == 1)
            await h.batch()
            #expect(dcEvents == 1)
            h.world.displays[1].isActive = true
            h.world.deliver(2, .enabledFlag)
            await h.batch()
            #expect(h.log.contains("record DELL S2725DC DELL S27: enabled elsewhere"))
            #expect(record(dc)?.disabledID == nil && row(c, dc)?.state == .on)
        }
    }
}
