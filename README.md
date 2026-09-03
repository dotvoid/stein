# Stein

**A macOS status-bar app that remembers where your windows were, per display
setup, and puts them back when the displays come back.**

[![CI](https://github.com/dotvoid/stein/actions/workflows/ci.yml/badge.svg)](https://github.com/dotvoid/stein/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)
![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)

Undock a MacBook and macOS piles every window onto the built-in screen. Redock it
and macOS restores the *displays* but not the *windows* - window frames belong to
apps, and no system service tracks layouts per display setup. Stein is that
missing service.

It learns as you work, so there is nothing to save and nothing to configure. When
your displays change, it puts your desk back and tells you exactly what it did.

```
┌─────────────────────────────────────────┐
│ Built-in Retina Display + S27C900P      │
│    Learning · layout remembered         │
│    Last: 14 windows, 1 retried · 2m ago │
│ ─────────────────────────────────────── │
│ Put Windows Back                  ⌃⌥⌘R  │
│ Remember This Layout              ⌃⌥⌘S  │
│ Undo Last Restore                 ⌃⌥⌘Z  │
│ ─────────────────────────────────────── │
│ Pause Learning                          │
│ Open at Login                           │
│ Advanced                              ▸ │
│ ─────────────────────────────────────── │
│ Quit Stein                              │
└─────────────────────────────────────────┘
```

## What it does

- **Learns while you work.** Every couple of seconds Stein notes what changed on
  the desk, and files it under a fingerprint of the displays attached right now.
  What gets recorded is what *you* changed: a window only updates its remembered
  place when it moved while you were at the keyboard. macOS piling windows onto
  the laptop screen when a display disconnects satisfies neither test, so a pile
  is never mistaken for a layout.
- **Puts windows back on display change.** When the display configuration
  settles, Stein looks up the layout for that desk and restores position, size and
  display for every window it can confidently identify.
- **Works across Mission Control Spaces.** A layout covers every Space, not just
  the one in front of you. Windows elsewhere are remembered and left alone until
  you switch to their Space, at which point they are seated - within about a
  quarter of a second of arriving.
- **Undo.** `⌃⌥⌘Z` returns the windows of the last restore to exactly where it
  found them. An automatic guess you cannot reverse is one you have to watch
  nervously.
- **Receipts.** Every restore says what it actually did - windows moved, already
  in place, retried, failed, not found, waiting on another Space, and how long it
  took - as a toast when it happens and a line in the menu afterwards. An app
  that moves your windows unasked should be accountable about it. The full
  history is in **Advanced → Copy Diagnostics**.

Stein does one job: watch, learn, put back.

### What it deliberately never touches

Minimized windows, full-screen windows, and hidden (`⌘H`) apps. For all of these,
moving the window is worse than leaving it alone.

A window on another Space is a different case, and used to be lumped in with
these. It is remembered, and moved when you arrive at its Space - never while it
is out of sight, where the frame cannot be verified and nobody would see the
result. Mostly it is not even a choice: whether an app offers its off-Space
windows to the Accessibility API is up to the app, and most do not, so there is
usually nothing there to move. That they still *exist* is established from the
window server's own list instead - which is what stops a Space switch reading as
the user having closed everything they walked away from.

## Install

There is no notarized release yet - that needs a paid Developer ID - so building
from source is the supported path. It takes about a minute and needs no Xcode,
only the Command Line Tools.

```sh
git clone https://github.com/dotvoid/stein.git
cd stein
./build.sh --install --run
```

That assembles `Stein.app`, ad-hoc signs it, copies it to `/Applications` and
launches it.

Then **grant Accessibility access** when prompted (System Settings › Privacy &
Security › Accessibility). Moving another app's windows is a privileged operation
on macOS, so Stein can do nothing at all until you allow it. The app polls until
the grant appears, so there is no need to relaunch.

Requirements: macOS 14 Sonoma or later, Apple Silicon or Intel, Swift 6
(`xcode-select --install`).

### Rebuilding

Ad-hoc signatures change on every build, and macOS then lists the app as allowed
while silently denying it - which looks exactly like Stein being broken. So when
you rebuild, reset the grant and approve it again:

```sh
./build.sh --install --reset-permission --run
```

Stein also says so when this happens, rather than sitting there looking busy.

## Using it

| Keys | Action |
|---|---|
| `⌃⌥⌘R` | Put windows back - restore this desk's layout now |
| `⌃⌥⌘S` | Remember this layout now |
| `⌃⌥⌘Z` | Undo the last restore |

Everything else is in the status-bar menu: the current desk, whether a layout is
on file for it, what the last restore did, pause, and open-at-login.

**Advanced → Copy Diagnostics** puts the full report on the clipboard. Prefer it
over `Stein --check`: macOS grants Accessibility to a bundle, so the running app
can list your windows while the same binary run from a terminal is attributed to
the terminal and usually cannot.

`Stein --check` prints the same diagnostic report - permission state, desk fingerprint,
every window Stein considers placeable, and what is on file for this desk - then
exits without starting the UI. It is the fastest way to explain a surprising
restore, and the right thing to paste into a bug report:

```sh
/Applications/Stein.app/Contents/MacOS/Stein --check
```

## How it works

The feature list is small; the correctness burden is not. These are the parts that
decide whether an app like this works or slowly ruins your layouts.

**Display identity.** Displays are keyed by `CGDisplayCreateUUIDFromDisplayID`,
falling back to a vendor/model/serial composite for virtual and DisplayLink panels
that have no UUID. `CGDirectDisplayID` is never stored: the window server recycles
it on every reconnect, so it can identify a display now but never remember one.

**Desk fingerprint.** `v2|<uuid>:<w>x<h>|…` sorted by UUID - which panels, at
which sizes. The *arrangement* is deliberately excluded. v1 included display
origins, and real usage showed why that was wrong: macOS reported the same two
panels as left-adjacent and then as stacked within a minute of a reconnect, which
forked one desk into two and orphaned the layout already learned. Nothing is lost
by ignoring it, because every window is recorded relative to its own display's
origin.

**One coordinate space.** Geometry comes from `CGDisplayBounds`, which is
top-left origin - the same space the Accessibility API speaks. `NSScreen.frame` is
bottom-left origin and is used only to look up display names, so nothing ever
needs flipping.

**Window identity.** macOS exposes no public, persistent window ID, so matching
runs on evidence: a matching `CGWindowID` (via the private
`_AXUIElementGetWindow`, resolved through `dlsym` so a future macOS that drops it
degrades instead of failing to launch) is decisive; an exact title is strong; a
drifted title, the same ordinal among an app's windows, and an unchanged position
are weaker. Assignment is greedy over the sorted candidates, strictly one-to-one,
with deterministic tie-breaks.

Two rules keep it honest. A title resemblance below 0.35 similarity counts for
nothing, because edit distance always returns *some* similarity, and treating a 9%
resemblance as partial proof is how a window lands in another window's slot. And a
pair scoring below the confidence floor is refused outright: sharing an app and
nothing else is not grounds to move anything. Leaving a window alone is always
recoverable; putting it somewhere it never was is not.

**Placement that verifies itself.** Setting a frame through the Accessibility API
is a request, not a command: apps clamp sizes, snap to their own grids, and
Chromium/Electron windows re-measure themselves right after a move. So Stein
writes position then size, waits, reads the frame back, and if it did not land,
retries with the order reversed - size then position - which is what the
re-measuring apps need. A window that refuses to shrink below its own minimum
counts as landed, because the position is what you notice.

**Resolution changes.** Each snapshot stores the absolute frame, the offset within
its display, the display size and the fractional frame. Replaying onto the same
display size uses the pixel offsets verbatim; a display that came back at a
different resolution gets proportional placement. Either way the result is clamped
inside the display, shrinking the window first if it cannot fit.

**Cheap idling.** A full scan is dozens of cross-process Accessibility
round-trips, and on an idle desk every one is wasted. Each tick first digests
every window's position from a single `CGWindowListCopyWindowInfo` call - sorted
by window number, so raising a window is not mistaken for a layout change - and
only runs the real scan when that digest moves.

**The learning race.** This is the part that decides whether the app is safe.
Learning has to stop *before* macOS starts evacuating windows, or the pile-up on
the built-in display gets recorded as the laptop-only layout and overwrites the
good one. So Stein:

1. Freezes on `CGDisplayRegisterReconfigurationCallback`'s
   `beginConfigurationFlag` - the earliest possible warning.
2. Treats a fingerprint change noticed by its own timer as a display change too,
   in case a callback is missed.
3. Waits for the display configuration to go quiet before acting, because macOS
   emits a burst of reconfiguration events and restoring mid-burst just gets
   undone.
4. Restores, then suspends learning briefly, so what gets learned is the restored
   layout rather than an intermediate state.
5. Refuses to remember an empty desk, which is almost always a measurement failure
   - a hung app, a locked screen, a fresh login - and never a real layout.
6. Re-checks the fingerprint *after* measuring and throws the measurement away if
   it changed, because a scan takes long enough that displays can move during it.

If a desk has no stored layout, Stein adopts what is on screen and says so instead
of rearranging anything.

See [RESEARCH.md](RESEARCH.md) for why macOS behaves this way, and how the
alternatives approach it.

## Privacy

Stein needs Accessibility access, which is a broad permission, so it is worth
being precise about what it does with it:

- It reads window titles, positions and sizes, and it moves windows. That is all.
- Nothing is sent anywhere. There is no network code, no analytics, no crash
  reporting and no update check.
- Everything it remembers is plain JSON you can read, edit or delete:

```
~/Library/Application Support/Stein/
  layouts.json    remembered layout per desk (most recent 32 desks)
  receipts.json   lifetime counters and the last restore report
```

Writes are atomic, because the likeliest moment for an interruption is exactly
when Stein is writing: the lid is closing, the dock is being pulled. An
interruption between writing and swapping leaves a `.tmp-…` sibling behind, so
Stein sweeps any that are old enough to be certainly abandoned when it starts.

## Development

```sh
swift build        # compile
./test.sh          # 109 tests, 14 suites
./build.sh         # build/Stein.app
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the layout of the code and what is
worth knowing before changing it.

## Prior art and credits

Stein exists because [Putback](https://putback.app) got the problem statement
right: this is a *restoring* problem, not a *snapping* problem. Putback is a paid,
closed-source app, and worth the money if you would rather buy than build. Stein
is an independent project with no affiliation to it, written from the same problem
and the public macOS APIs.

The wider landscape, roughly:

- **Restorers** - [Stay](https://cordlessdog.com/stay/) has done display-aware
  layout restore for over a decade; Moom has saved layouts with display triggers;
  BetterStage, ScreenPlace, MacLayout and HopTab all work this side of the fence.
- **Snappers** - [Rectangle](https://rectangleapp.com), Magnet, Swish. Excellent
  at arranging the window in front of you, and structurally unable to help with
  docking.
- **Tilers** - Amethyst, yabai. Automatic, but they impose a layout rather than
  preserving yours.

## License

MIT - see [LICENSE](LICENSE).
