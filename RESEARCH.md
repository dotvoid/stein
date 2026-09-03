# Why macOS loses your window layout

The design rationale behind Stein: why macOS loses your window layout, what a
solution has to do about it, and how the existing apps in this space approach it.

Sources are putback.app's public pages as they read in August 2026, quoted for
comparison and analysis, plus the macOS APIs any app in this category has to use.
Stein is not affiliated with Putback.

## The promise

> "Any layout you name. One key brings it back."

Putback is a macOS window manager whose pitch is narrow and concrete: undock a
MacBook and every window collapses onto one screen; redock it and macOS restores
the *displays* but not the *windows*. Putback remembers where windows were, per
display setup, and puts them back automatically.

Two features:

1. **Automatic layout memory.** It "quietly snapshots your desk as you go" - no
   saving, no configuration. When displays reconnect, "every window slides back
   to its exact place. Position, size, display, all of it."
2. **Scenes.** Named desk setups launched by hotkey: which apps are open, where
   each window sits, optionally which wallpaper is up. Designed in a visual
   "Scene Studio" by drawing boxes, and able to *launch* apps that are not
   running and seat them as they appear.

Pricing: $19 one-time (1 Mac), $29 family (5), $79 team (20). No subscription,
7 day trial, no card. macOS 14+, Apple Silicon and Intel. Marketing leans on
"0 trackers" and "your layouts never leave your Mac", and on showing counters of
what the app actually did - "receipts, not marketing".

## Why macOS loses your layout

Putback's own explanation matches the platform reality:

- macOS treats all displays as **one coordinate space**. Every window has a
  position inside it. Unplug a display and that region of the space stops
  existing, so the window server evacuates the orphaned windows onto whatever
  screen is left.
- macOS restores the *display arrangement* on reconnect but "keeps no memory of
  which window sat where in that setup".
- Architecturally: "Windows belong to apps, not to the system." Each app owns
  its frames and macOS is deliberately conservative about moving them behind an
  app's back. There is no system service tracking layouts per display
  configuration, so there is nothing to restore from.

## The mechanism any such app must use

None of this is secret; it is the only route macOS offers.

| Need | API |
|---|---|
| Read/write another app's window frames | Accessibility API (`AXUIElement`, `kAXPosition`/`kAXSize`), requires the Accessibility permission |
| Notice display changes | `CGDisplayRegisterReconfigurationCallback`, `NSApplication.didChangeScreenParametersNotification` |
| Identify a display across reconnects | `CGDisplayCreateUUIDFromDisplayID` (**not** `CGDirectDisplayID`, which is recycled) |
| Identify a window | `CGWindowID` - obtainable from an AX element only via the private `_AXUIElementGetWindow` |
| Know which windows are on the current Space | `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` |
| Set wallpaper | `NSWorkspace.setDesktopImageURL(_:for:)` |
| Global hotkeys without Input Monitoring | Carbon `RegisterEventHotKey` |

Coordinate spaces are a trap: AX positions are **global, top-left origin**,
while `NSScreen.frame` is bottom-left origin. Mixing them silently flips
everything vertically on multi-display setups. Using `CGDisplayBounds` for
display geometry keeps one coordinate space end to end.

## The hard parts (and what Putback admits about them)

The interesting engineering is not "set the frame". It is:

1. **Window identity.** macOS exposes no public, persistent window ID. Matching
   "is this the same window?" must be inferred from window number, title (which
   drifts constantly), ordinal position among an app's windows, and last known
   frame.
2. **Placement is a request, not a command.** Putback's compatibility page is
   candid: Electron/Chromium apps "sometimes re-measure their own window
   immediately after a move, which can nudge the frame slightly off target". So
   it does not move and walk away - it **verifies after moving**, and retries
   with the writes reordered, "size-then-position instead of the standard
   position-then-size".
3. **Scope discipline.** Minimized, full-screen, other-Space and hidden (Cmd+H)
   windows are deliberately excluded: "only records and restores what is visible
   on your current Space per display". These are the cases where moving a window
   is worse than leaving it.
4. **The learning race** (Putback does not spell this out, but it is the crux).
   A passive learner must stop learning *before* macOS starts evacuating
   windows. Otherwise, the instant you undock, it records the pile-up on the
   built-in display as "the laptop-only layout" and overwrites the good one. Get
   this wrong and the app slowly eats the very layouts it exists to protect.

## The category, and where Stein sits

The category split matters more than any feature table:

**Snappers** - Rectangle (free, MIT), Magnet, Moom, BetterSnapTool, Swish.
These arrange the window you are looking at, on demand, into halves/thirds/
quarters. They are excellent at that and structurally cannot help with docking:
there is no memory of a desk and no trigger on display change. Moom is the
exception among snappers - it has saved layouts and can trigger them on monitor
changes - but requires you to save layouts manually and is, in Putback's words, a
"power tool" needing setup.

**Tilers** - Amethyst, yabai. Automatic, but they impose a layout rather than
preserving yours, and yabai wants SIP partially disabled.

**Restorers** - Stay (the classic prior art), BetterStage, ScreenPlace,
MacLayout, HopTab, and Putback. This is the real comparison set. Putback's
claimed edges:

- **Learns continuously**, so the layout restored is the one you were actually
  using, not a snapshot you remembered to save three weeks ago. Manual-save
  restorers go stale, which is the failure mode that makes people stop trusting
  them.
- **Per-display-setup memory**, so the laptop desk, the desk dock and the
  meeting-room projector each keep their own arrangement.
- **Verify-and-retry placement**, which is what makes Electron apps land.
- **No configuration** to get the main benefit, versus Moom's setup burden.
- **macOS 14+** versus ScreenPlace's macOS 26+ floor.
- **One-time price**, no subscription.

Honest counterpoints: Stay has done display-config-aware restore for well over a
decade, Moom covers snapping *and* layouts for a similar price, and Rectangle is
free if snapping is all you want. Putback's genuine differentiator is the
combination of passive learning, a restore path that verifies its own work, and
scenes that can launch apps.

## What that implies for building one

The feature list is small. The correctness burden is not, and it sits almost
entirely in four places:

1. Freeze learning the instant displays move (the race above).
2. Debounce until the display configuration is quiet - macOS emits a burst of
   reconfiguration events, and restoring mid-burst just gets undone.
3. Verify every placement and retry with reordered writes.
4. Identify displays by UUID and windows by evidence, never by the IDs macOS
   recycles.

Everything else - menu bar UI, scenes, hotkeys, wallpapers, receipts - is
ordinary AppKit work.

Stein takes that list as its whole remit: passive learning, a restore path that
verifies its own work, display identity that survives a reconnect, and a matcher
that would rather do nothing than move a window into the wrong slot. It is MIT
licensed, so the reasoning above is checkable against the code rather than taken
on trust.
