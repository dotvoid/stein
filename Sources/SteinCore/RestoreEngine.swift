import CoreGraphics
import Foundation

/// The result of a restore: what happened, and how to take it back.
public struct RestoreOutcome {
  public var report: RestoreReport
  /// Where the windows Stein actually moved were sitting beforehand.
  ///
  /// Recorded because an automatic restore is a guess made on the user's behalf,
  /// and a guess the user cannot reverse is one they have to watch nervously.
  /// Only genuinely moved windows are listed, so undoing puts back exactly what
  /// changed and touches nothing else.
  public var undo: [WindowSnapshot]

  public init(report: RestoreReport, undo: [WindowSnapshot]) {
    self.report = report
    self.undo = undo
  }
}

public enum RestoreEngine {
  /// Puts a remembered layout back onto the desk that exists now.
  public static func restore(
    windows snapshots: [WindowSnapshot],
    topology: Topology,
    kind: RestoreReport.Kind,
    topologyLabel: String? = nil,
    live: [LiveWindow]? = nil,
    existing: Set<CGWindowID>? = nil
  ) -> RestoreOutcome {
    let start = Date()
    let liveWindows = live ?? WindowScanner.scan()
    let existingIDs = existing ?? WindowScanner.allWindowIDs()
    let match = WindowMatcher.match(
      live: liveWindows.map { ($0, $0.identity) },
      snapshots: snapshots
    )

    var unchanged = 0
    var placed = 0
    var retried = 0
    var failed = 0
    var deferred = 0
    var undo: [WindowSnapshot] = []

    for pair in match.pairs {
      // Matched, and deliberately not touched: the window is on one of the
      // user's other Spaces. Moving it would mean rearranging a desk nobody is
      // looking at, on the strength of a frame that cannot be verified. It is
      // put back when the user goes there.
      guard placeable(pair.live) else {
        deferred += 1
        continue
      }
      guard let display = targetDisplay(for: pair.snapshot, in: topology) else {
        failed += 1
        continue
      }
      let before = pair.identity.frame
      let outcome = WindowPlacer.place(pair.live, at: pair.snapshot.targetFrame(on: display))
      switch outcome {
      case .unchanged:
        unchanged += 1
      case .placed:
        placed += 1
      case .retried:
        retried += 1
      case .failed:
        failed += 1
      }
      if outcome == .placed || outcome == .retried,
         let host = Geometry.display(hosting: before, among: topology.displays) {
        undo.append(
          WindowSnapshot(
            bundleID: pair.identity.bundleID,
            appName: pair.snapshot.appName,
            windowID: pair.identity.windowID,
            title: pair.identity.title,
            ordinal: pair.identity.ordinal,
            frame: before,
            display: host
          )
        )
      }
    }

    // A snapshot that matched nothing has either lost its window or is waiting on
    // another Space, and the difference decides whether this restore counts as
    // having failed. Nothing in the Accessibility API can tell them apart, so the
    // window-number list does it.
    var missing = 0
    for snapshot in match.unmatchedSnapshots {
      if let id = snapshot.windowID, existingIDs.contains(id) {
        deferred += 1
      } else {
        missing += 1
      }
    }

    let report = RestoreReport(
      kind: kind,
      at: Date(),
      topologyLabel: topologyLabel ?? topology.label,
      unchanged: unchanged,
      placed: placed,
      retried: retried,
      failed: failed,
      missing: missing,
      deferred: deferred,
      duration: Date().timeIntervalSince(start)
    )
    return RestoreOutcome(report: report, undo: undo)
  }

  public static func restore(
    _ snapshot: LayoutSnapshot,
    topology: Topology,
    kind: RestoreReport.Kind
  ) -> RestoreOutcome {
    restore(
      windows: snapshot.windows,
      topology: topology,
      kind: kind,
      topologyLabel: topology.label
    )
  }

  /// `LiveWindow` is generic to the matcher, so the Space check is reached
  /// through a cast rather than a constraint.
  static func placeable<Live>(_ live: Live) -> Bool {
    (live as? LiveWindow)?.isOnCurrentSpace ?? true
  }

  /// Which display a remembered window should go back to.
  ///
  /// Its own display when that display is still attached. Otherwise the main one,
  /// where proportional placement takes over - a window that owned the left third
  /// of a missing monitor gets the left third of the screen that is left, which is
  /// wrong in absolute terms and right in every way the user cares about.
  static func targetDisplay(for snapshot: WindowSnapshot, in topology: Topology) -> DisplayInfo? {
    topology.display(id: snapshot.displayID) ?? topology.main
  }
}
