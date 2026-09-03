# Contributing to Stein

Stein has one job - watch the desk, learn the layout, put the windows back - and
the bar for changes is whether they make that job more reliable. Bug reports about
windows landing in the wrong place are the most valuable thing you can send.

## Getting set up

No Xcode required; the Command Line Tools are enough.

```sh
xcode-select --install     # if you have neither
git clone https://github.com/dotvoid/stein.git
cd stein
swift build                # compile
./test.sh                  # run the tests
./build.sh --install --run  # assemble, install and launch
```

`test.sh` exists because the tests use Swift Testing. With a full Xcode install
that works out of the box; with only the Command Line Tools the framework sits
outside the default search paths and needs explicit `-F` and `-rpath` flags,
because SIP strips `DYLD_FRAMEWORK_PATH` from the test helper. The script detects
which situation you are in.

`build.sh` assembles the app bundle by hand - `Info.plist`, a generated icon, an
ad-hoc signature - since there is no Xcode project.

### After every rebuild

Ad-hoc signatures change on each build, so macOS may keep listing Stein as allowed
while silently denying it. Use:

```sh
./build.sh --install --reset-permission --run
```

## Reporting a bug

Include the output of:

```sh
/Applications/Stein.app/Contents/MacOS/Stein --check
```

It prints the permission state, the desk fingerprint, every window Stein considers
placeable and what is on file for the current desk - which is usually enough to
explain a surprising restore. Add the receipt line from the menu
(`Receipts › Last`) and, if the problem is app-specific, the app and its version.

## How the code is laid out

`SteinCore` is the engine and has no UI. `Stein` is the app: menus, toasts,
hotkeys, and the decisions about *when* to act.

| File | Responsibility |
|---|---|
| `SteinCore/Geometry.swift` | fractions, clamping, which display hosts a rect |
| `SteinCore/Topology.swift` | display identity and the desk fingerprint |
| `SteinCore/WindowSnapshot.swift` | what was recorded, and where to put it back |
| `SteinCore/WindowMatcher.swift` | is this the same window as before? |
| `SteinCore/WindowScanner.swift` | what exists, what is touchable, and the cheap digest |
| `SteinCore/WindowLedger.swift` | which window positions the user is answerable for |
| `SteinCore/UserPresence.swift` | was anybody at the keyboard when that moved? |
| `SteinCore/Session.swift` | is the screen locked, so is the desk a lie? |
| `SteinCore/WindowPlacer.swift` | move it, then check that it moved |
| `SteinCore/RestoreEngine.swift` | match, place, count, defer, record undo |
| `SteinCore/UndoRecord.swift` | where the last restore found what it moved |
| `SteinCore/Displays.swift` | CoreGraphics display enumeration |
| `SteinCore/Accessibility.swift` | typed AX wrapper with messaging timeouts |
| `SteinCore/Store.swift` | atomic JSON persistence and version migration |
| `SteinCore/RestoreReport.swift` | receipts |
| `SteinCore/HotkeySpec.swift` | a key combination, as Carbon wants it |
| `Stein/Coordinator.swift` | when to learn, when to freeze, when to restore |
| `Stein/MenuController.swift` | the status-bar menu |
| `Stein/Toast.swift` | the receipt panel |
| `Stein/HotkeyCenter.swift` | Carbon global hotkeys |
| `Stein/Diagnostics.swift` | `--check` |
| `Tools/MakeIcon.swift` | draws the app icon |

## Things worth knowing before you change something

These are settled decisions with reasons. Reversing one is fine - bring evidence.

- **Geometry is `CGDisplayBounds`, never `NSScreen.frame`.** AX coordinates are
  top-left origin; `NSScreen` is bottom-left. Using one space end to end avoids a
  whole class of silent vertical-flip bugs. `NSScreen` is used only for names.
- **The desk fingerprint is panels and sizes, not the arrangement.** Keying on
  display origins was tried and reverted: macOS reports a transient arrangement
  during reconnect, which forked one desk into two and orphaned a learned layout.
- **`CGDirectDisplayID` is never persisted.** It is recycled on reconnect.
- **Two different `CGWindowID`s mean "not the same window"**, not "low score".
- **The matcher would rather do nothing.** Refusing to move a window is always
  recoverable; moving it into another window's slot is not. That asymmetry decides
  every close call - hence the confidence floor and the title-similarity
  threshold.
- **Never remember an empty desk.** An empty scan is nearly always a measurement
  failure, and overwriting a good layout with it cannot be undone.
- **Learning must freeze before macOS evacuates windows.** This is the core
  safety property. Anything that delays the freeze, or lets a snapshot be filed
  during a display change, is a serious bug rather than a rough edge.
- **The AX scan stays gated behind the cheap digest.** A background app that
  beachballs the machine every two seconds gets uninstalled no matter how well it
  restores.
- **Undo is one-shot.** Undoing an undo is a toggle nobody can keep track of.
- **Swift 5 language mode.** Strict Swift 6 concurrency over AppKit singletons and
  Carbon C callbacks is a separate project. Engine state is instead confined to
  one serial queue, hopping to main via `MainThread.sync`.

## Tests

Run `./test.sh`. The suite covers the pure logic - geometry, fingerprints,
matching, persistence, report wording - which is where the subtle bugs live and
the only part that can be tested without a window server.

The AX and AppKit layers cannot be unit tested meaningfully. Verify those with
`--check` and by actually docking and undocking. If you change matching or
placement, say in the PR what you exercised: which apps, which display setup.

New behaviour in `SteinCore` should come with tests. New behaviour in the app
layer usually cannot have them; describe the manual check instead.

## Style

- Two-space indent, lines under 100 characters.
- Doc comments explain *why*, not what. The what is readable from the code; the
  why is where all the macOS-specific reasoning lives, and it is the reason this
  code is maintainable at all.
- No `any` escape hatches around the AX API - keep the typed wrappers in
  `Accessibility.swift` and extend them if something is missing.
