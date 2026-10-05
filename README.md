# DisplayTweaks

Per-display HiDPI for macOS 26 on Apple Silicon. For each external display, DisplayTweaks turns **HiDPI** on or off from its menu bar item:

- **HiDPI on:** a 2560×1440 panel keeps a UI that looks like 2560×1440, but it is rendered into a 5120×2880 framebuffer and downsampled by the display pipeline, so text is Retina-sharp. The panel keeps its refresh rate and its place in the display arrangement.
- **How:** WindowServer already generates a native-size HiDPI mode for these panels but hides it from the public mode list. DisplayTweaks reads WindowServer's full mode table and selects that hidden mode. There is no virtual display, no mirroring, no override file and no admin rights.
- macOS itself saves the choice, so it survives replugging, login and reboot.

It is a menu bar agent app with no Dock icon, built to cost nothing while idle. It is for personal use only: self-signed, not sandboxed, not notarized. It needs no Accessibility permission.

Requirements: Swift 6.3 Command Line Tools (Xcode is only needed for the tests) and the macOS 26 SDK.

## One-time setup (per Mac)

**Create the signing identity.** Run this in **Terminal.app**, not through Claude Code:

```sh
./scripts/make-cert.sh
```

It creates the self-signed "DisplayTweaks Local Signing" code-signing identity in your login keychain. It asks for your login keychain password (hidden input) and shows a system dialog to trust the certificate. The stable identity is what lets installed copies accept updates. The script is safe to re-run: it exits if the identity already exists. Check the result with:

```sh
security find-identity -v -p codesigning
```

## Build, install and run

Production DisplayTweaks is installed from the release DMG into `/Applications/DisplayTweaks.app` and updates itself (see [Releases and updates](#releases-and-updates)). A local build is a separate development copy, **DisplayTweaks Dev**, so testing never touches production:

```sh
./scripts/build-app.sh
```

The script does the following:
1. Builds in debug mode. Debug builds compile in the dev-only behaviour: no update checks, and the event log goes to its own `DisplayTweaks Dev` folder.
2. Assembles `.build/DisplayTweaks Dev.app` with bundle ID `local.displaytweaks.dev` and executable `DisplayTweaksDev`, and signs it with "DisplayTweaks Local Signing". Remembered choices and Launch at Login are kept separately from production, because they belong to the bundle ID.
3. Quits any running DisplayTweaks, production included, because two copies would both switch displays.
4. Installs the app to `~/Applications/DisplayTweaks Dev.app` and removes the build copy, so only one bundle with ID `local.displaytweaks.dev` exists.
5. Launches the app.

Any extra arguments are passed on to the app, for example `./scripts/build-app.sh --log-events`. `BUNDLE_ONLY=1 ./scripts/build-app.sh` builds and signs the production bundle `.build/DisplayTweaks.app` without installing it (the release workflow uses this).

To go back to production:

```sh
pkill -x DisplayTweaksDev; open /Applications/DisplayTweaks.app
```

To run the self-test of the pure logic (it exits before any UI, and a failure gives a non-zero exit status):

```sh
swift run DisplayTweaks --self-test
```

## Usage

The menu bar item shows a display icon (with "DEV" in development builds). Its menu lists every external display, left to right, with two rows each:

- **‹Display name› — HiDPI** — the toggle, checked when HiDPI is on. Choose it to switch HiDPI on or off. Displays with the same name get " 1", " 2", … The main display's name ends in " (Main)", after any number: `DELL 1 (Main) — HiDPI`.
- An info row below it with the display's state:

| State | Info row |
|---|---|
| Off | `Off` |
| On | `Looks like 2560 × 1440 (5120 × 2880 backing) · 144 Hz` |
| Failed | `Failed — no HiDPI mode at 120 Hz. Choose HiDPI to retry.` or `Failed — macOS rejected the change. Choose HiDPI to retry.` Choose the toggle to try again. The menu bar icon shows a warning badge. Only turning HiDPI on can fail this way: if macOS rejects turning it off, the display stays On and shows as On. |
| Not available | `HiDPI not available` — macOS generates no native-size HiDPI mode for this display (for example Sidecar, AirPlay, DisplayLink, or a panel too large for the GPU). Its toggle is dimmed. |

Below the displays:

- **Turn Off HiDPI on All Displays** switches every connected display that is on back to native. It is dimmed when none is on.
- **Launch at Login**, **Automatic Updates**, **Check for Updates…** and **Quit DisplayTweaks**.

With no external display the menu says "No External Display Connected". If this version of macOS lacks the private functions DisplayTweaks uses, it says "HiDPI Unavailable" with a warning icon, and the rest of the app keeps working.

HiDPI uses the display's current refresh rate. To get HiDPI at another rate, pick the rate in System Settings first, then turn HiDPI on.

## Behaviour notes

- **HiDPI stays on after you quit.** macOS saves the choice itself, so quitting or uninstalling DisplayTweaks changes nothing. To go back to native, use **Turn Off HiDPI on All Displays with every display connected** before quitting or uninstalling. Disconnected displays keep their saved HiDPI.
- **Remembered per display.** DisplayTweaks remembers each display's choice and turns HiDPI back on after a reconnect, wake or launch if macOS didn't restore it. On first sight it adopts whatever the display is already set to, including HiDPI set by another app.
- **System Settings wins.** Picking another resolution for a display in System Settings counts as turning HiDPI off for it, and DisplayTweaks won't turn it back on. Within 10 s of a reconnect or wake, changes aren't read this way, because macOS may still be restoring the display's mode.
- **The screen blinks** for about a second on each switch, as with any resolution change. Displays never move in the arrangement.
- DisplayTweaks reacts to display events only: it costs nothing while idle.

## Known limitations

- DisplayTweaks uses three private CoreGraphics functions. A macOS update may change or remove them; DisplayTweaks then shows "HiDPI Unavailable" instead of switching.
- Only displays for which macOS generates the hidden native-size HiDPI mode are supported.
- HiDPI stays on after you quit (see above).
- A resolution change in System Settings turns HiDPI off for that display.

## Releases and updates

DisplayTweaks checks GitHub Releases (`omega123456/DisplayTweaks`, which must be public) at launch and then every hour. When a newer version exists, it asks whether to update now. If you accept, it downloads the zip and installs it over the running copy, but only if the download is signed with the same "DisplayTweaks Local Signing" certificate. Then it relaunches. The menu has **Automatic Updates** and **Check for Updates…**. Dev builds never update.

Releases are made with `./scripts/release.sh` (bumps the version, verifies the build, commits, tags `vX.Y.Z` and pushes); the tag triggers `.github/workflows/release.yml`, which publishes a DMG and a zip.

## Event log (diagnostics)

Launch with `--log-events` to append millisecond-timestamped plain-text lines to:

```
~/Library/Logs/DisplayTweaks/events.log        # production
~/Library/Logs/DisplayTweaks Dev/events.log    # DisplayTweaks Dev
```

The file is cleared at each launch and removed when the app starts without the flag. To read it:

```sh
./scripts/build-app.sh --log-events
tail -f ~/Library/Logs/DisplayTweaks\ Dev/events.log
```

The log is a file rather than the unified log because the Claude Code sandbox blocks `/usr/bin/log`.

## Claude Code sandbox note

SwiftPM only works outside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package`, `./scripts/build-app.sh`, `./scripts/test.sh` and `./scripts/coverage.sh` from the sandbox. The exclusion only applies when the whole command is one of these, so don't pipe or chain them (no `|`, `&&` or `cd … &&`). `make-cert.sh` is interactive, so run it in Terminal.app.

## Acknowledgements

Crisp, FineDisplay, S-Display and RDM documented that macOS generates hidden HiDPI modes and how to select them. DisplayTweaks uses no code from any of them.
