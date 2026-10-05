import AppKit
import Testing
@testable import DisplayTweaks

extension Desktop {
    /// HiDPIController over `FakeDisplayWorld`: never a real display. Display 1 is the DSM at x 0, display 2 the DC
    /// at x 2560 (Dell tables from `SelfTest.dellTable`: HiDPI 144 Hz = mode 113, default native 144 Hz = mode 78).
    @MainActor @Suite struct HiDPIControllerTests {
        let h = Harness()
        let dsm = "DELL S2725DSM-UUID", dc = "DELL S2725DC-UUID"

        func dsmDisplay(on: Bool = false, hz: Int = 144) -> FakeDisplayWorld.Display { FakeDisplayWorld.dell(1, "DELL S2725DSM", x: 0, on: on, hz: hz) }
        func dcDisplay(on: Bool = false) -> FakeDisplayWorld.Display { FakeDisplayWorld.dell(2, "DELL S2725DC", x: 2560, on: on) }
        func record(_ uuid: String) -> DisplayRecord? { DisplayStore().record(for: uuid) }
        func remember(_ choice: DisplayRecord.Choice, _ uuid: String, name: String = "DELL S2725DSM") {
            DisplayStore().save(DisplayRecord(choice: choice, name: name), for: uuid)
        }
        func state(_ c: HiDPIController, _ uuid: String) -> Displays.State? { c.rows.first { $0.uuid == uuid }?.state }
        func events(_ name: String) -> Int { h.log.components(separatedBy: "event \(name)").count - 1 }

        // MARK: Turn on / off (R-4, R-5, R-10)

        @Test func turnOn() async {
            h.world.displays = [dsmDisplay()]
            let c = h.controller()
            var changes = 0
            c.onChange = { changes += 1 }
            #expect(state(c, dsm) == .off)
            c.toggle(dsm)
            #expect(h.world.switches == ["1:113"])
            #expect(state(c, dsm) == .on)
            #expect(record(dsm)?.choice == .on)
            #expect(c.icon == .on)
            #expect(changes == 1)
            #expect(h.log.contains("switch DELL S2725DSM DELL S27: on target 2560x1440 density 2.0 144 Hz mode 113 result=0 "
                                   + "duration=1.00 s now 2560x1440 pt 5120x2880 px 144 Hz"))
            #expect(h.log.contains("record DELL S2725DSM DELL S27: remember on"))
            // Its own callbacks: begin ignored, set-mode → one batch, nothing to do.
            await h.batch()
            #expect(h.log.contains("event DELL S2725DSM DELL S27: flags=modeChanged decision=nothing"))
            #expect(h.world.switches.count == 1)
        }

        @Test func noModeAtRate() {
            h.world.displays = [dsmDisplay(hz: 100)]
            let c = h.controller()
            c.toggle(dsm)
            #expect(h.world.switches.isEmpty)
            #expect(state(c, dsm) == .failed(.noMode(100)))
            #expect(record(dsm)?.choice == .off) // unchanged
            #expect(c.icon == .failed)
            #expect(h.log.contains("failure DELL S2725DSM DELL S27: no HiDPI mode at 100 Hz"))
        }

        @Test func transactionErrorThenRetry() {
            h.world.displays = [dsmDisplay()]
            let c = h.controller()
            h.world.error = .illegalArgument
            c.toggle(dsm)
            #expect(h.world.switches == ["1:113"])
            #expect(state(c, dsm) == .failed(.rejected))
            #expect(record(dsm)?.choice == .off)
            #expect(h.log.contains("result=1001"))
            #expect(h.log.contains("failure DELL S2725DSM DELL S27: macOS rejected the change"))
            // Choosing the toggle retries R-4.
            h.world.error = .success
            c.toggle(dsm)
            #expect(state(c, dsm) == .on)
            #expect(record(dsm)?.choice == .on)
        }

        @Test func notOnAfterSwitch() {
            h.world.displays = [dsmDisplay()]
            let c = h.controller()
            h.world.ignoresSwitch = true
            c.toggle(dsm)
            #expect(state(c, dsm) == .failed(.rejected))
            #expect(record(dsm)?.choice == .off)
        }

        @Test func turnOff() {
            h.world.displays = [dsmDisplay(on: true)]
            let c = h.controller()
            #expect(state(c, dsm) == .on)
            c.toggle(dsm)
            #expect(h.world.switches == ["1:78"]) // the default-bit native mode
            #expect(state(c, dsm) == .off)
            #expect(record(dsm)?.choice == .off)

            // No native density-1 entry at all: rejected and logged, nothing switched, still On (R-3, R-10).
            h.world.displays = [dsmDisplay(on: true)]
            h.world.displays[0].table = h.world.displays[0].table.filter { $0.density == 2 }
            let fresh = h.controller()
            fresh.toggle(dsm)
            #expect(h.world.switches == ["1:78"])
            #expect(state(fresh, dsm) == .on)
            #expect(record(dsm)?.choice == .on)
            #expect(Displays.canTurnOffAll(fresh.rows))
            #expect(h.log.contains("failure DELL S2725DSM DELL S27: macOS rejected the change"))
        }

        @Test func turnOffAtZeroHz() {
            h.world.displays = [dsmDisplay(on: true)]
            h.world.displays[0].refresh = 0
            let c = h.controller()
            c.toggle(dsm)
            #expect(h.world.switches == ["1:78"]) // the default-bit native mode, not 81 (0 isn't read as 60 for Off)
            #expect(state(c, dsm) == .off)
        }

        /// R-3, R-10: a rejected Off shows reality, not Failed; the choice stays On and Turn Off All still includes it.
        @Test(arguments: [false, true])
        func failedTurnOffShowsReality(_ completesWithoutChange: Bool) {
            h.world.displays = [dsmDisplay(on: true)]
            let c = h.controller()
            if completesWithoutChange { h.world.ignoresSwitch = true } else { h.world.error = .illegalArgument }
            c.toggle(dsm)
            #expect(h.world.switches == ["1:78"])
            #expect(state(c, dsm) == .on)
            #expect(c.icon == .on)
            #expect(record(dsm)?.choice == .on)
            #expect(h.log.contains("failure DELL S2725DSM DELL S27: macOS rejected the change"))
            #expect(Displays.canTurnOffAll(c.rows))
            c.turnOffAll()
            #expect(h.world.switches == ["1:78", "1:78"])
            #expect(h.log.contains("turn off all: 1 displays switched"))
        }

        @Test func toggleIgnoresUnknownAndNotAvailable() {
            h.world.displays = [FakeDisplayWorld.ipad(3, x: 0)]
            let c = h.controller()
            c.toggle("IPAD-UUID")
            c.toggle("nope")
            #expect(h.world.switches.isEmpty)
            #expect(state(c, "IPAD-UUID") == .notAvailable)
            #expect(c.icon == .normal)
        }

        // MARK: Turn Off All, serial switching (R-8, R-9, DD-7)

        @Test func turnOffAllInListOrder() {
            h.world.displays = [dcDisplay(on: true), FakeDisplayWorld.ipad(3, x: 5120), dsmDisplay(on: true)]
            let c = h.controller()
            #expect(Displays.canTurnOffAll(c.rows))
            c.turnOffAll()
            #expect(h.world.switches == ["1:78", "2:78"]) // list order (left to right), one after another
            #expect(h.log.contains("turn off all: 2 displays switched"))
            #expect(record(dsm)?.choice == .off && record(dc)?.choice == .off)
            #expect(!Displays.canTurnOffAll(c.rows))
        }

        @Test func launchReappliesSerially() {
            h.world.displays = [dcDisplay(), dsmDisplay()] // world order ≠ list order
            remember(.on, dsm)
            remember(.on, dc, name: "DELL S2725DC")
            let c = h.controller()
            #expect(h.world.registrations == 1)
            #expect(h.world.switches == ["1:113", "2:113"])
            #expect(state(c, dsm) == .on && state(c, dc) == .on)
            #expect(h.log.contains("event DELL S2725DSM DELL S27: flags=added decision=reapply"))
        }

        // MARK: First sight, names (R-1, R-6)

        @Test func adoptionAtFirstSight() {
            h.world.displays = [dsmDisplay(on: true), dcDisplay()]
            remember(.off, "IPAD-UUID", name: "Old name")
            h.world.displays.append(FakeDisplayWorld.ipad(3, x: 5120))
            _ = h.controller()
            #expect(record(dsm) == DisplayRecord(choice: .on, name: "DELL S2725DSM"))
            #expect(record(dc) == DisplayRecord(choice: .off, name: "DELL S2725DC"))
            #expect(record("IPAD-UUID")?.name == "iPad") // the name is rewritten when it changed
            #expect(h.world.switches.isEmpty)
            #expect(h.log.contains("display DELL S2725DSM DELL S27: state=on eligible=yes current=2560x1440 pt 5120x2880 px 144 Hz"))
            #expect(h.log.contains("display iPad IPAD-UUI: state=notAvailable eligible=no current=1920x1080 pt 1920x1080 px 60 Hz"))
            #expect(h.log.contains("record DELL S2725DSM DELL S27: adopted on at first sight"))
            #expect(h.log.contains("record DELL S2725DC DELL S27: adopted off at first sight"))
        }

        // MARK: Re-apply (R-6)

        @Test func reapplyOnAdded() async {
            h.world.displays = [dsmDisplay(on: true)]
            let c = h.controller()
            h.world.unplug(1)
            await h.batch()
            #expect(c.rows.isEmpty)
            h.world.plug(dsmDisplay()) // macOS dropped HiDPI
            await h.batch()
            #expect(h.world.switches == ["1:113"])
            #expect(state(c, dsm) == .on)
            #expect(h.log.contains("event DELL S2725DSM DELL S27: flags=added decision=reapply"))
        }

        @Test(arguments: [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification])
        func reapplyOnWake(_ name: Notification.Name) async {
            h.world.displays = [dsmDisplay(on: true)]
            let c = h.controller()
            h.world.displays[0].current = SelfTest.native144 // dropped during sleep, no callback
            h.ws.center.post(name: name, object: nil)
            await h.batch()
            #expect(h.world.switches == ["1:113"])
            #expect(state(c, dsm) == .on)
        }

        @Test func unsettledRefreshIsRechecked() async {
            h.world.displays = [dsmDisplay()]
            h.world.displays[0].refresh = 0
            remember(.on, dsm)
            let c = h.controller()
            #expect(h.log.contains("decision=recheck"))
            #expect(h.world.switches.isEmpty)
            h.world.advance(Displays.debounce) // still 0 Hz: give up until the next event
            #expect(h.log.contains("flags=recheck decision=nothing"))
            #expect(state(c, dsm) == .off && record(dsm)?.choice == .on)

            h.world.unplug(1)
            await h.batch()
            var d = dsmDisplay()
            d.refresh = 0
            h.world.plug(d)
            await h.batch()
            h.world.displays[0].refresh = nil // settled
            h.world.advance(Displays.debounce)
            #expect(h.world.switches == ["1:113"])
        }

        /// DD-6: the re-check batch decides like an add but doesn't restart the 10 s settle grace.
        @Test func recheckKeepsGrace() async {
            h.world.displays = [dsmDisplay(on: true)]
            let c = h.controller()
            h.world.advance(11)
            h.world.unplug(1)
            await h.batch()
            var d = dsmDisplay()
            d.refresh = 0
            h.world.plug(d) // added at t₀ = 111.5, unsettled → re-check
            await h.batch()
            h.world.displays[0].current = SelfTest.hiDPI144 // macOS restored HiDPI
            h.world.displays[0].refresh = nil
            h.world.advance(Displays.debounce) // the re-check batch, started at t₀ + 0.5
            #expect(h.log.contains("flags=recheck decision=nothing"))
            h.world.advance(9) // t₀ + 10: outside a grace from t₀, inside one restarted by the re-check
            h.world.setMode(1, SelfTest.native144)
            await h.batch()
            #expect(h.log.contains("event DELL S2725DSM DELL S27: flags=modeChanged decision=rememberOff"))
            #expect(record(dsm)?.choice == .off)
            withExtendedLifetime(c) {}
        }

        // MARK: Changes made elsewhere (R-7, DD-6)

        @Test func changeElsewhereMeansOff() async {
            h.world.displays = [dsmDisplay(on: true)]
            let c = h.controller()
            h.world.advance(11) // outside the settle grace
            h.world.setMode(1, SelfTest.other144) // System Settings
            await h.batch()
            #expect(record(dsm)?.choice == .off)
            #expect(state(c, dsm) == .off)
            #expect(h.log.contains("event DELL S2725DSM DELL S27: flags=modeChanged decision=rememberOff"))
            // Not re-applied after a later replug at native 1×.
            h.world.unplug(1)
            await h.batch()
            h.world.plug(dsmDisplay())
            await h.batch()
            #expect(h.world.switches.isEmpty)
        }

        @Test func lateRestoreInsideGrace() async {
            h.world.displays = [dsmDisplay(on: true)]
            let c = h.controller()
            h.world.advance(11)
            h.world.unplug(1)
            await h.batch()
            h.world.plug(dsmDisplay(on: true)) // macOS restored HiDPI
            await h.batch()
            h.world.advance(3)
            h.world.setMode(1, SelfTest.native144) // a late restore, 3 s after the add
            await h.batch()
            #expect(record(dsm)?.choice == .on)
            #expect(state(c, dsm) == .off)
            #expect(h.world.switches.isEmpty)
        }

        @Test func ownSwitchWindow() async {
            h.world.displays = [dsmDisplay()]
            let c = h.controller()
            h.world.advance(11)
            c.toggle(dsm)
            h.world.setMode(1, SelfTest.native144) // inside 2 s of our own completion
            await h.batch()
            #expect(record(dsm)?.choice == .on)
        }

        @Test func hiDPIChosenElsewhereIsRememberedOn() async {
            h.world.displays = [dsmDisplay()]
            let c = h.controller()
            h.world.advance(11)
            h.world.setMode(1, SelfTest.hiDPI144) // another app
            await h.batch()
            #expect(record(dsm)?.choice == .on)
            #expect(state(c, dsm) == .on)
            #expect(h.log.contains("decision=rememberOn"))
        }

        @Test func absentDisplayDropsItsFailure() async {
            h.world.displays = [dsmDisplay(hz: 100)]
            let c = h.controller()
            c.toggle(dsm)
            #expect(state(c, dsm) == .failed(.noMode(100)))
            h.world.unplug(1)
            await h.batch()
            #expect(c.rows.isEmpty)
            h.world.plug(dsmDisplay(hz: 100))
            await h.batch()
            #expect(state(c, dsm) == .off)
        }

        // MARK: Debounce (DD-4)

        @Test func debounceMergesCallbacks() async {
            h.world.displays = [dsmDisplay(on: true)]
            let c = h.controller() // the controller holds the trampoline's handler weakly: keep it alive
            h.world.deliver(1, .addFlag)
            h.world.deliver(1, .setModeFlag)
            await settle()
            h.world.advance(0.3)
            h.world.deliver(1, .setModeFlag) // restarts the debounce
            await settle()
            h.world.advance(0.3)
            #expect(events("DELL S2725DSM") == 1) // only the launch batch so far
            h.world.advance(0.3)
            #expect(events("DELL S2725DSM") == 2)
            #expect(h.log.contains("event DELL S2725DSM DELL S27: flags=added,modeChanged decision=nothing"))
            withExtendedLifetime(c) {}
        }

        @Test func beginConfigurationIgnored() async {
            h.world.displays = [dsmDisplay()]
            let c = h.controller() // the controller holds the trampoline's handler weakly: keep it alive
            h.world.deliver(1, .beginConfigurationFlag)
            await settle()
            h.world.advance(1)
            #expect(events("DELL S2725DSM") == 1)
            h.world.deliver(1, .movedFlag) // other flags only re-snapshot
            await h.batch()
            #expect(h.log.contains("event DELL S2725DSM DELL S27: flags=none decision=nothing"))
            withExtendedLifetime(c) {}
        }

        /// A main-display change (set-main callback) only re-snapshots; the rows move " (Main)" after the debounce (R-1).
        @Test func mainDisplayChangeUpdatesRows() async {
            h.world.displays = [dsmDisplay(on: true), dcDisplay()]
            h.world.main = 1
            let c = h.controller() // the controller holds the trampoline's handler weakly: keep it alive
            #expect(c.rows.map(\.title) == ["DELL S2725DSM (Main) — HiDPI", "DELL S2725DC — HiDPI"])
            h.world.setMain(2)
            await settle()
            #expect(c.rows.map(\.title) == ["DELL S2725DSM (Main) — HiDPI", "DELL S2725DC — HiDPI"]) // still debouncing
            h.world.advance(Displays.debounce)
            #expect(c.rows.map(\.title) == ["DELL S2725DSM — HiDPI", "DELL S2725DC (Main) — HiDPI"])
            #expect(h.log.contains("event DELL S2725DC DELL S27: flags=none decision=nothing"))
            #expect(h.world.switches.isEmpty)
            #expect(record(dc)?.name == "DELL S2725DC") // the record keeps the name without (Main)
            withExtendedLifetime(c) {}
        }

        // MARK: Unavailable (R-11)

        @Test func unavailableDoesNothing() {
            h.available = false
            h.world.displays = [dsmDisplay()]
            let c = h.controller()
            #expect(h.world.registrations == 0)
            #expect(c.rows.isEmpty)
            #expect(c.icon == .unavailable)
            c.toggle(dsm)
            #expect(h.world.switches.isEmpty)
            #expect(record(dsm) == nil)
        }
    }
}
