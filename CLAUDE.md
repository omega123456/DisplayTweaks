# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

DisplayTweaks turns HiDPI on or off per external display on macOS 26 (Apple Silicon) by selecting the native-size HiDPI mode WindowServer generates but hides. It is an `LSUIElement` menu bar agent (`local.displaytweaks`) for personal use: self-signed, not sandboxed, not notarized, no Accessibility permission. It is a single SwiftPM executable target that uses system frameworks only (never SwiftUI, xibs or asset catalogs), built with the Swift 6.3 Command Line Tools. The only dependency is swift-snapshot-testing, used by the test target alone; tests run with Xcode's toolchain via `scripts/test.sh`. `Package.swift` pins Swift language mode v5. Conventions, scripts and the test approach are ported from `~/Projects/FancyMacZones` (DD-9: copied and renamed, nothing shared at build time).

## Commands

```sh
swift build                                 # debug build (compile check)
swift run DisplayTweaks --self-test         # pure-logic checks; exits before any UI, non-zero on failure
./scripts/test.sh                           # menu outline + behaviour tests + SelfTest (Tests/DisplayTweaksTests), offscreen; extra args go to swift test (--filter …)
./scripts/coverage.sh                       # test.sh with LLVM line coverage of Sources/DisplayTweaks; fails below COVERAGE_MIN (default 90); COVERAGE_HTML=1 → .build/xcode/coverage/index.html
./scripts/build-app.sh                      # debug "DisplayTweaks Dev" build → sign → quit running copies (prod too) → install to ~/Applications → launch
./scripts/build-app.sh --log-events         # extra args are passed to the app
BUNDLE_ONLY=1 ./scripts/build-app.sh        # signed production bundle .build/DisplayTweaks.app, not installed (CI)
tail -f ~/Library/Logs/DisplayTweaks\ Dev/events.log
pkill -x DisplayTweaksDev; open /Applications/DisplayTweaks.app   # back to production
./scripts/release.sh                        # (owner runs it) bump Info.plist version, verify, commit, tag vX.Y.Z, push → .github/workflows/release.yml
```

- **Sandbox:** SwiftPM fails inside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package`, `./scripts/build-app.sh`, `./scripts/test.sh` and `./scripts/coverage.sh`, but only when the command is exactly one of these. Don't pipe, chain or prefix them (`|`, `&&`, `cd … &&`). `BUNDLE_ONLY=1 ./scripts/build-app.sh` is not exempt (the env prefix): inside the sandbox it reports the signing identity as missing, so run it with the sandbox disabled. Sandboxed `codesign -dv` shows `Authority=(unavailable)`; get signing evidence unsandboxed.
- **App icon:** `scripts/make-icon.swift` draws `Resources/AppIcon.icns` (committed). Build it inside the sandbox, run it with the sandbox disabled (`iconutil` silently fails inside it):
  ```sh
  swiftc -module-cache-path "$TMPDIR/mc" scripts/make-icon.swift -o "$TMPDIR/make-icon"
  "$TMPDIR/make-icon"     # sandbox disabled; pass the sandbox's TMPDIR if it differs
  ```
- **Two suites.** `--self-test` covers the pure logic and needs only the CLT. To add a logic check, add a `check(...)` in `Sources/DisplayTweaks/SelfTest.swift`. It counts failures explicitly, because `assert` is compiled out of release builds. `Tests/DisplayTweaksTests/SelfTests.swift` also runs it under `swift test`, so coverage counts it. `SelfTest.swift` itself is excluded from the coverage total.
- **Tests** (`Tests/DisplayTweaksTests`, Swift Testing + swift-snapshot-testing) never touch the real desktop: no real display switching, no status item on screen, login item, dialogs or real UserDefaults.
  - **Toolchain:** the library imports XCTest, which only Xcode ships. So `scripts/test.sh` runs `swift test` with `DEVELOPER_DIR` set to Xcode and its own `.build/xcode` scratch path. `xcode-select` stays on the CLT (6.3) for app builds. Xcode's license must be accepted (sudo), so the owner runs that.
  - **Seams:** everything outside the app goes through a replaceable static: `Env` (workspace, defaults, activate, terminate) in `App.swift`, `DisplaySystem.backend`, `MenuBar.showsStatusItem`, `LaunchAtLogin.service`, `EventLog.url` and the `Updater` closures and `session`. Production never changes them. New code that reaches the system (a new AppKit global, a private function, a system call) adds a seam and fakes it in `Harness` (`Fakes.swift`), which installs fresh fakes for every test.
  - **Harness:** a fake workspace with its own notification center (wake is posted there), fake `DisplaySystem` availability (`h.available`), a `FakeDisplayWorld` (`h.world`) behind the rest of `DisplaySystem.backend`, a temp folder for `events.log`, a `local.displaytweaks.tests` defaults suite, fake login-item service, updater dialogs and relaunch. Tests that use it are nested in the serialized `Desktop` suite. Assert on behaviour through `h.log` (EventLog lines), store state and the counters.
  - **FakeDisplayWorld:** per display a CGS mode table (`SelfTest.dellTable`, shared with `--self-test`), native size and current mode; `switches` records every transaction as `"<id>:<mode number>"`; `error` and `ignoresSwitch` inject failures; `main` sets the main display; `plug`, `unplug`, `setMode`, `setMain` and `deliver` send callbacks through the real `DisplaySystem.trampoline`; a manual clock (`now`, `advance(_:)`) drives the debounce, the settle grace and the own-switch window. `h.controller()` returns a started controller; `await h.batch()` lets the trampoline's main-queue hops arrive and fires the debounce. Keep the controller in a `let` while events are delivered: the trampoline's handler holds it weakly.
  - **Pitfalls:** never `performClick` (its tracking loop can end the run loop Swift Testing drains on, which exits the run silently with status 0); send the action instead (`NSApp.sendAction`).
  - **Menu outlines:** NSMenu only draws while tracking on a real display, so the status-item menu is compared as text with `outline(_:)` (`Fakes.swift`): `✓` for on, 4 spaces per indentation level, `(disabled)`, `---` for separators; the Dev debug row's version is masked. References are `__Snapshots__/MenuBarTests/MenuBar.<case>.txt`; tests are debug builds, so every reference starts with the debug row. To add a state, add a `Case` and its setup. The first run of a new case records its reference and reports a failure; delete a `.txt` to re-record it, then check it by eye before committing.
  - **Coverage:** `scripts/coverage.sh` gates on 90 % lines of all `Sources/DisplayTweaks` except `SelfTest.swift`. What stays uncovered is the real system call inside each seam (including `DisplaySystem.transaction`), the CFUserNotification prompt and `main()`. `DisplaySystemTests.realSnapshot` runs the production read-only snapshot for real and is skipped when no display is online; it is the only test that reads real displays, and nothing ever switches one.
  - **CI:** tests aren't run there; the references were recorded on the owner's Mac.
- **Dev vs production:** production is `/Applications/DisplayTweaks.app` (`local.displaytweaks`, from the DMG, self-updating). `build-app.sh` builds **DisplayTweaks Dev**: a debug build with bundle ID `local.displaytweaks.dev` and executable `DisplayTweaksDev`, so UserDefaults (the display records) and the login item are separate. `#if DEBUG` gates the dev behaviour: no updater, its own log folder (`DisplayTweaks Dev`), the debug menu row and the "DEV" status-item title.
- **Launch the installed app** (with the script or `open ~/Applications/DisplayTweaks\ Dev.app`) for real use, not the binary in `.build/`.
- `scripts/make-cert.sh` is interactive (keychain password, trust dialog). The owner runs it in Terminal.app, not you. It creates the "DisplayTweaks Local Signing" identity; its SHA-1 is pinned in `.github/workflows/release.yml` (uppercase in the identity check, lowercase in the requirement check), and installed copies only accept updates signed by it.
- `--log-events` writes to a file because the sandbox blocks `/usr/bin/log`.

## Architecture

All work runs on the main thread and is event-driven.

```
   CG reconfiguration callback (debounced 0.5 s)   NSWorkspace did-wake / screens-did-wake   app launch   menu actions
                     └───────────────────────────────────────┴─────────────────┬─────────────┴──────────────┘
                                                                               ▼
                              HiDPIController: cached snapshot · per-display state & failure · own-switch window ·
                              settle grace · serial switching · re-apply on add/wake/launch · Turn Off All
                                  │ decisions                 │ switch / read                │ records
                                  ▼                           ▼                              ▼
                         Displays (pure model)        DisplaySystem (seam)            DisplayStore (UserDefaults)
                         DisplayRecord · modes ·      symbol resolution ·             display.<UUID> JSON records
                         eligibility · state ·        availability · snapshot ·
                         mode choice · event          transaction · trampoline ·
                         decision · names · copy ·    clock · debounce
                         icon

  MenuBar (NSStatusItem, menu built on open) ── reads controller.rows / icon / isAvailable ── sends toggle / Turn Off All
  AppDelegate (App.swift): wiring · LaunchAtLogin · Updater · EventLog
```

Cross-cutting rules that need several files to see:

- **Private functions (DD-1, ADR 50914964):** exactly three, `CGSGetNumberOfDisplayModes`, `CGSGetDisplayModeDescriptionOfLength` and `CGSConfigureDisplayMode`, resolved once with `dlsym` from `/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics` in `DisplaySystem.swift` and called through `@convention(c)` types that return nothing. A missing one means "HiDPI Unavailable" (R-11), never a crash. No SkyLight, SLS or other CGS calls anywhere.
  The switch is `CGBeginDisplayConfiguration` → `CGSConfigureDisplayMode(token, id, modeNumber)` → `CGCompleteDisplayConfiguration(.permanently)` (DD-3); success is the completion result plus a re-read showing the expected state.
- **Mode table and matching (DD-2):** a 0xDC-byte descriptor per entry: number @0, flags @4, width @8, height @12 (points), refresh `UInt16` @0xBE, density `Float32` @0xD0. The count is initialised to 0, the index is 0-based, the buffer is zeroed before every call, and implausible entries are skipped (NFR-4). The mode number passed to the switch is the descriptor's field at offset 0, never the index. Modes are matched by attributes (native size, density 2 or 1, current refresh rounded), never by a stored mode number; the record never holds mode numbers or native sizes. The native size comes from the public 1× mode flagged native in every snapshot; the current state (On = native points at 2× pixels) from the public current mode. HiDPI duplicates: the first in table order; density 1: the default-mode bit 0x4 wins, falling back to the default-bit native entry at any rate.
- **Events only (DD-4, ADRs 73be782a and 59a2e005):** the CoreGraphics reconfiguration callback, launch and NSWorkspace did-wake / screens-did-wake (through `Env.workspace`). The static `DisplaySystem.trampoline` maps add/enabled → added, remove/disabled → removed, set-mode → mode changed, ignores begin-configuration callbacks entirely, treats any other flag as "re-snapshot only", and hops to the main thread. Flags are merged per display over a 0.5 s one-shot debounce restarted by each callback (a generation counter; the seam is a plain `asyncAfter`). Wake marks every display added; launch is one batch with every display added. Absent displays leave the cache. An automatic re-apply of a native-1× display at 0 Hz is re-checked once after one more debounce (the `recheck` flag, which decides like added but doesn't restart the settle grace); a user-started turn-on treats 0 Hz as 60, Turn Off keeps 0 and falls back to the default-bit native mode. No polling, no App Nap assertion, no other timers.
- **Failed is for turn-on only (R-3, R-10):** a failed Off (transaction error, still On after the re-read, or no density-1 native mode) is logged as a `failure` line and keeps the remembered choice, but the display shows what the re-read says (`Displays.showsFailure`).
- **Settle grace and own-switch window (DD-6):** per display UUID. The settle grace lasts 10 s from added or wake; the own-switch window 2 s from the completion of DisplayTweaks' transaction for that display. Both are judged at the arrival of the batch's first callback, through the `DisplaySystem.backend.now` clock. Inside either, a display leaving HiDPI isn't read as "changed elsewhere" (R-7).
- **All decisions live in `Displays.swift`** as `static func`s or value types, so `SelfTest` can cover them without UI. **Escalation:** if a decision rule is missing or wrong, stop and report it to the owner; never put decision logic in the controller or the menu.
- **Seams:** every system call goes through `DisplaySystem.backend` or another seam above; production seam closures that change something are one-line system calls (the transaction is the one short `DisplaySystem.transaction` function).
- **No `CGSize` in Sources:** the AC grep `\bCGS[A-Za-z]+` must print only the three private functions, so the model uses its own `Displays.Size`.
- **Persistence (DD-5, ADR e6a117ad):** `DisplayStore` keeps one JSON `DisplayRecord` (choice, name, schema version) per display UUID under `display.<UUID>` in `Env.defaults`; unreadable data is ignored. There is no `Settings` type: the Updater owns its `autoUpdateDisabled` key.
- **Idle cost (NFR-1):** no timers except the hourly update check (production only) and the one-shot 0.5 s debounce. The menu is built only when it opens (DD-8), with no key equivalents.
- **Main indicator (owner request, overrides part of R-1):** the main display's toggle row reads `‹name›[ N] (Main) — HiDPI` (FancyMacZones' convention). `Entry.isMain` comes from `CGDisplayIsMain` in the snapshot; a main change arrives as a set-main callback, which only re-snapshots. It is display copy only (`Displays.names`): the record name (`baseName`), the order and the info row never carry it.
- **Menu copy** lives in `Displays` and uses typographic characters: `×`, `·`, `—`, `…` and `’` (U+2019).
- Code comments cite "requirement N" (R-N) and "DD-N". These refer to `.agent/plans/2026-10-05_displaytweaks_plan.md`, which holds the full spec, the wireframes and the reasons behind the constants. Its approved mockup is in `.agent/plans/assets/`.
- Self-contained (NFR-8): no build-time or run-time reference to, and no code from, any external tool.

## Architectural decisions (binding)

`.agent/adr/` is an append-only decision ledger, governed by `.agent/ADR_POLICY.md`. Never edit, rename or delete an existing ADR. To reverse one, write a new ADR with a `## Relationship to previous decisions` section. Four ADRs apply; the other ten dated 2026-10-05 record the superseded virtual-display design and do not apply. Read the relevant ADR before you change:
- the switching technique, the private functions or the descriptor layout (`…--50914964.md`)
- display events, debouncing or re-apply (`…--73be782a.md`, amended by `…--59a2e005.md`: settle grace, native-only re-apply, per-display own-switch window)
- persistence (`…--e6a117ad.md`)

## Verifying behaviour

Acceptance criteria are tagged **[agent]** (builds, `--self-test`, test and coverage runs, file contents, `codesign`/`plutil` output, `events.log` lines read from the log file) or **[owner]** (live displays, System Settings, sleep/wake, reboot, Activity Monitor, releases).

- The owner keeps using the desktop while agents work. Agents never switch a real display.
- `open`, `pgrep`, `system_profiler`, `codesign` trust checks and `/usr/bin/log` need the sandbox disabled, which auto mode may deny; report such checks as not verified rather than forcing them.
