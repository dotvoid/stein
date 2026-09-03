import CoreGraphics
import Foundation
import Testing
@testable import SteinCore

@Suite("Layout merging")
struct LayoutMergeTests {
  private let laptop = DisplayInfo(
    id: "laptop",
    name: "Built-in Retina Display",
    bounds: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    isMain: true
  )
  private let external = DisplayInfo(
    id: "dell",
    name: "DELL U3219Q",
    bounds: CGRect(x: -1028, y: -2160, width: 3840, height: 2160),
    isMain: false
  )

  private func window(
    _ name: String,
    on display: DisplayInfo,
    at offset: CGPoint = CGPoint(x: 20, y: 20),
    id: UInt32
  ) -> WindowSnapshot {
    WindowSnapshot(
      bundleID: "com.example.\(name)",
      appName: name,
      windowID: id,
      title: name,
      ordinal: 0,
      frame: CGRect(
        x: display.bounds.minX + offset.x,
        y: display.bounds.minY + offset.y,
        width: 900,
        height: 700
      ),
      display: display
    )
  }

  private func layout(_ windows: [WindowSnapshot]) -> LayoutSnapshot {
    LayoutSnapshot(
      fingerprint: "v2|laptop:1800x1169|dell:3840x2160",
      topologyLabel: "Built-in Retina Display + DELL U3219Q",
      capturedAt: Date(timeIntervalSince1970: 1000),
      windows: windows.sorted {
        ($0.bundleID, $0.ordinal, $0.title) < ($1.bundleID, $1.ordinal, $1.title)
      }
    )
  }

  /// The guarantee the whole design rests on: a write about one window cannot
  /// disturb the remembered position of any other.
  @Test("Only the authored window changes")
  func authoredWindowReplacesOnlyItself() {
    let stored = layout([
      window("chrome", on: external, id: 1),
      window("zed", on: external, id: 2),
      window("mail", on: laptop, id: 3)
    ])
    var verdict = WindowLedger.Verdict()
    verdict.authored = [window("chrome", on: laptop, at: CGPoint(x: 500, y: 100), id: 1)]

    let merged = stored.merging(verdict)

    #expect(merged.windows.count == 3)
    let byApp = Dictionary(uniqueKeysWithValues: merged.windows.map { ($0.appName, $0) })
    #expect(byApp["chrome"]?.displayID == "laptop")
    #expect(byApp["zed"]?.displayID == "dell")
    #expect(byApp["mail"]?.displayID == "laptop")
    #expect(byApp["zed"]?.frame == stored.windows.first { $0.appName == "zed" }?.frame)
  }

  @Test("A merge with nothing authored leaves the layout alone")
  func emptyVerdictChangesNothing() {
    let stored = layout([window("chrome", on: external, id: 1)])
    let merged = stored.merging(WindowLedger.Verdict())
    #expect(merged.windows == stored.windows)
    #expect(stored.describesSameDesk(as: merged))
  }

  @Test("A closed window is dropped and the rest are untouched")
  func closedWindowIsRemoved() {
    let chrome = window("chrome", on: external, id: 1)
    let mail = window("mail", on: laptop, id: 3)
    let stored = layout([chrome, mail])
    var verdict = WindowLedger.Verdict()
    verdict.closed = [chrome]

    let merged = stored.merging(verdict)
    #expect(merged.windows.count == 1)
    #expect(merged.windows.first?.appName == "mail")
  }

  @Test("A window the layout has never seen is added")
  func newWindowIsAppended() {
    let stored = layout([window("mail", on: laptop, id: 3)])
    var verdict = WindowLedger.Verdict()
    verdict.authored = [window("zed", on: external, id: 9)]

    let merged = stored.merging(verdict)
    #expect(merged.windows.count == 2)
    #expect(merged.windows.contains { $0.appName == "zed" && $0.displayID == "dell" })
  }

  /// The merge has to work against a layout written in an earlier session, where
  /// every window number has since been reissued.
  @Test("A window is recognised across a restart, by title rather than number")
  func matchesAcrossStaleWindowNumbers() {
    let stored = layout([
      window("chrome", on: external, id: 1),
      window("mail", on: laptop, id: 3)
    ])
    var verdict = WindowLedger.Verdict()
    // Same app and title, brand new window number.
    verdict.authored = [window("chrome", on: laptop, at: CGPoint(x: 40, y: 40), id: 8_812)]

    let merged = stored.merging(verdict)
    #expect(merged.windows.count == 2)
    #expect(merged.windows.first { $0.appName == "chrome" }?.displayID == "laptop")
  }

  @Test("Merging keeps the scanner's ordering so an idle desk does not churn")
  func orderingIsStable() {
    let stored = layout([
      window("zed", on: external, id: 2),
      window("chrome", on: external, id: 1)
    ])
    var verdict = WindowLedger.Verdict()
    verdict.authored = [window("alpha", on: laptop, id: 5)]

    let merged = stored.merging(verdict)
    let bundles = merged.windows.map(\.bundleID)
    #expect(bundles == bundles.sorted())
  }

  // MARK: - Adoption

  /// The gap that made other Spaces look unsupported: a window can only be
  /// restored if it is in the layout, and it could only get into the layout by
  /// being dragged.
  @Test("Windows the layout has never heard of are the ones worth adopting")
  func unknownWindowsAreIdentified() {
    let stored = layout([window("chrome", on: external, id: 1)])
    let onScreen = [
      window("chrome", on: external, id: 1),
      window("kitty", on: laptop, id: 7),
      window("zed", on: laptop, id: 8)
    ]
    let unknown = stored.unknownWindows(among: onScreen).map(\.appName).sorted()
    #expect(unknown == ["kitty", "zed"])
  }

  @Test("Adopted windows join the layout without disturbing what is there")
  func adoptedWindowsAreAdded() {
    let chrome = window("chrome", on: external, id: 1)
    let stored = layout([chrome])
    let verdict = WindowLedger.Verdict(adopted: [window("kitty", on: laptop, id: 7)])

    let merged = stored.merging(verdict)
    #expect(merged.windows.count == 2)
    #expect(merged.windows.first { $0.appName == "chrome" }?.frame == chrome.frame)
    #expect(merged.windows.contains { $0.appName == "kitty" })
  }

  @Test("A window already in the layout is not adopted again")
  func knownWindowsAreNotAdopted() {
    let chrome = window("chrome", on: external, id: 1)
    let stored = layout([chrome])
    // Same window, moved, and with a reissued number after an app restart.
    let moved = window("chrome", on: laptop, at: CGPoint(x: 30, y: 30), id: 9_001)
    #expect(stored.unknownWindows(among: [moved]).isEmpty)
  }

  /// Adoption must not undo the protection it sits next to: a piled window that
  /// the layout already remembers keeps its remembered place.
  @Test("Adoption does not overwrite a remembered position")
  func adoptionDoesNotClobber() {
    let chrome = window("chrome", on: external, id: 1)
    let stored = layout([chrome])
    let piled = window("chrome", on: laptop, at: CGPoint(x: 0, y: 39), id: 1)

    #expect(stored.unknownWindows(among: [piled]).isEmpty)
    #expect(stored.merging(WindowLedger.Verdict()).windows == stored.windows)
  }

  /// The whole point, stated as the scenario that started it: the pile is never
  /// authored, so the layout on file is still the good one afterwards.
  @Test("A pile authors nothing, so the remembered layout survives it")
  func pileLeavesLayoutIntact() {
    var ledger = WindowLedger()
    let good = [
      window("chrome", on: external, id: 1),
      window("zed", on: external, id: 2),
      window("mail", on: laptop, id: 3)
    ]
    let stored = layout(good)
    ledger.seed(good)

    // Wake up: the external display is back, but its windows are on the laptop
    // and nobody put them there.
    let piled = [
      window("chrome", on: laptop, at: CGPoint(x: 0, y: 39), id: 1),
      window("zed", on: laptop, at: CGPoint(x: 0, y: 39), id: 2),
      window("mail", on: laptop, id: 3)
    ]
    let verdict = ledger.observe(piled, userWasActive: false)
    let merged = stored.merging(verdict)

    #expect(stored.describesSameDesk(as: merged))
    #expect(merged.windows.filter { $0.displayID == "dell" }.count == 2)
  }
}
