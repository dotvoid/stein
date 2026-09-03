import AppKit
import Foundation
import SteinCore

/// The report that explains a surprising restore: the desk fingerprint, the
/// windows Stein considers placeable, and what is on file for this desk.
///
/// Built as a string rather than printed, because the process that can answer the
/// interesting questions is usually not the one the user is typing into. Reading
/// windows needs an Accessibility grant, and macOS gives that to a *bundle*: the
/// running Stein.app has it, while `Stein --check` from a terminal is attributed
/// to the terminal, which almost never does. That asymmetry made the diagnostic
/// tool useless exactly when it was needed - three separate attempts to answer
/// one question about Spaces came back "unknown until Accessibility access is
/// granted" - so the menu can now produce the same report from inside the app.
enum Diagnostics {
  static func run() -> Never {
    print(report(store: Store()))
    exit(0)
  }

  static func report(store: Store) -> String {
    let topology = Displays.current()
    var out: [String] = []
    func line(_ text: String = "") { out.append(text) }

    line("Stein diagnostics")
    line("  accessibility: \(AX.isTrusted ? "granted" : "NOT GRANTED")")
    line("  session: \(Session.isActive ? "active" : "locked or switched away")")
    // The signal that decides whether a window that moved was moved by anybody.
    line(String(format: "  last user input: %.0fs ago", UserPresence.secondsSinceInput))
    let identity = AX.windowIDLookupAvailable ? "available" : "unavailable (titles only)"
    line("  window id lookup: \(identity)")
    line("  data folder: \(store.directory.path)")
    // Needs no Accessibility grant, so these are the runtime checks that still
    // work before permission is given.
    line("  desk digest: \(WindowScanner.deskDigest())")
    let onScreen = WindowScanner.windowIDsOnCurrentSpace().count
    let everywhere = WindowScanner.allWindowIDs().count
    line("  windows in the window server: \(onScreen) on this Space,"
      + " \(everywhere) in total")
    line()
    line("Desk: \(topology.label)")
    line("  fingerprint: \(topology.fingerprint)")
    for display in topology.displays {
      let bounds = display.bounds
      line("  - \(display.name)\(display.isMain ? " (main)" : "")")
      line("      id: \(display.id)")
      line("      bounds: \(Int(bounds.minX)),\(Int(bounds.minY))"
        + " \(Int(bounds.width))x\(Int(bounds.height))")
    }
    line()

    if AX.isTrusted {
      let windows = WindowScanner.scan()
      let here = windows.filter(\.isOnCurrentSpace)
      line("Placeable windows: \(here.count) on this Space,"
        + " \(windows.count - here.count) on others")
      for window in windows.sorted(by: { $0.identity.bundleID < $1.identity.bundleID }) {
        let frame = window.identity.frame
        let id = window.identity.windowID.map(String.init) ?? "-"
        line("  \(window.isOnCurrentSpace ? " " : "~")[\(id)]"
          + " \(window.identity.bundleID) #\(window.identity.ordinal)"
          + " \(Int(frame.minX)),\(Int(frame.minY))"
          + " \(Int(frame.width))x\(Int(frame.height))"
          + "  \(window.identity.title)")
      }
      // Whether an app offers its off-Space windows to the Accessibility API is
      // up to the app, so this count is unreliable and usually far below the real
      // number. Compare it with the window-server totals above: the difference is
      // the windows Stein knows exist but cannot see.
      line("  (~ marks a window on another Space: remembered, seated when you go"
        + " there. Most never appear here at")
      line("   all - apps vary - so the window-server counts above are what"
        + " establish those windows still exist.)")
    } else {
      line("Placeable windows: unknown - this process has no Accessibility grant")
      line("  macOS grants Accessibility to a bundle, so the running Stein.app has"
        + " it and this command does not:")
      line("  it is attributed to your terminal. Two ways to see the window list:")
      line("    - Stein's menu → Advanced → Copy Diagnostics (asks the app, which"
        + " is already trusted)")
      line("    - or grant your terminal Accessibility in System Settings →"
        + " Privacy & Security")
    }
    line()

    if let layout = store.layout(for: topology.fingerprint) {
      line("Remembered for this desk: \(layout.windows.count) windows"
        + " (captured \(layout.capturedAt))")
      // Per display, because the failure this catches is a layout that has every
      // window on one screen - which looks perfectly healthy as a total.
      for display in topology.displays {
        let count = layout.windows.filter { $0.displayID == display.id }.count
        line("  - \(display.name): \(count) window\(count == 1 ? "" : "s")")
      }
    } else {
      line("Remembered for this desk: nothing yet")
    }
    line("Desks on file: \(store.rememberedDesks.count)")
    let receipts = store.receipts
    line("Receipts: \(receipts.restores) restores,"
      + " \(receipts.windowsMoved) windows put back,"
      + " \(receipts.windowsFailed) refused,"
      + " \(receipts.layoutWrites) layout writes")
    if let last = receipts.lastReport {
      line("Last restore: \(last.title) · \(last.summary)")
    }
    return out.joined(separator: "\n")
  }
}
