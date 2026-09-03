import Foundation
import Testing
@testable import SteinCore

@Suite("Restore reports")
struct RestoreReportTests {
  @Test("A clean restore reads as a plain count and a duration")
  func cleanRestoreSummary() {
    let report = RestoreReport(
      kind: .displayChange, topologyLabel: "Built-in + Studio", placed: 14, duration: 0.83
    )
    #expect(report.summary == "14 windows, 0.8s")
    #expect(report.title == "Built-in + Studio")
  }

  @Test("One window is not pluralised")
  func singularWindow() {
    let report = RestoreReport(kind: .manual, topologyLabel: "Desk", placed: 1, duration: 0.1)
    #expect(report.summary == "1 window, 0.1s")
    #expect(report.title == "Layout restored")
  }

  @Test("Retries, failures and closed apps are all admitted to")
  func problemsAreReported() {
    let report = RestoreReport(
      kind: .displayChange,
      topologyLabel: "Desk",
      placed: 4,
      retried: 2,
      failed: 1,
      missing: 3,
      duration: 4.25
    )
    #expect(report.totalMoved == 6)
    #expect(report.title == "Desk")
    #expect(report.summary == "6 windows, 2 retried, 1 failed, 3 not found, 4.2s")
  }

  @Test("An undone restore says so")
  func undoTitle() {
    let report = RestoreReport(kind: .undo, topologyLabel: "Desk", placed: 6, duration: 0.4)
    #expect(report.title == "Restore undone")
    #expect(report.summary == "6 windows, 0.4s")
  }

  /// The receipt this project shipped with, from the morning the bug was found:
  /// a display change fired, the layout on file had one window in it, that window
  /// matched nothing, and `failed == 0` made the whole thing look like a success.
  @Test("A restore that moved nothing is not a success")
  func ineffectiveRestoreIsRecognised() {
    let report = RestoreReport(
      kind: .displayChange,
      topologyLabel: "Built-in Retina Display + DELL U3219Q",
      placed: 0,
      missing: 1,
      duration: 0.057
    )
    #expect(report.wasIneffective)
    #expect(report.summary == "0 windows, 1 not found, nothing moved, 0.1s")
  }

  @Test("A desk that already looked right is not ineffective")
  func nothingToDoIsNotIneffective() {
    // Windows found sitting where they belong are counted as placed, so a desk
    // that needed no work still reports having been handled.
    let report = RestoreReport(kind: .manual, topologyLabel: "Desk", placed: 6, duration: 0.1)
    #expect(!report.wasIneffective)
  }

  @Test("A restore with nothing to do at all is not ineffective")
  func emptyLayoutIsNotIneffective() {
    let report = RestoreReport(kind: .manual, topologyLabel: "Desk", duration: 0.01)
    #expect(!report.wasIneffective)
  }

  @Test("An undo is never judged ineffective")
  func undoIsExempt() {
    // Undo only ever replays frames Stein itself just moved away from, so a
    // window that has since closed is expected, not a symptom.
    let report = RestoreReport(kind: .undo, topologyLabel: "Desk", missing: 2, duration: 0.1)
    #expect(!report.wasIneffective)
  }

  @Test("Every window refusing to move is ineffective too")
  func totalFailureIsIneffective() {
    let report = RestoreReport(kind: .manual, topologyLabel: "Desk", failed: 4, duration: 0.9)
    #expect(report.wasIneffective)
  }

  @Test("A desk already in the right shape reports that, not a move")
  func unchangedIsItsOwnOutcome() {
    let report = RestoreReport(
      kind: .spaceChange, topologyLabel: "Desk", unchanged: 6, duration: 0.1
    )
    #expect(report.totalMoved == 0)
    #expect(!report.wasIneffective)
    #expect(report.summary == "0 windows, 6 already right, 0.1s")
  }

  @Test("Windows waiting on another Space are not a failure")
  func deferredIsNotIneffective() {
    let report = RestoreReport(
      kind: .displayChange, topologyLabel: "Desk", placed: 2, deferred: 9, duration: 0.4
    )
    #expect(!report.wasIneffective)
    #expect(report.summary == "2 windows, 9 on other Spaces, 0.4s")
  }

  /// A restore with nothing but deferred work has done its whole job: those
  /// windows are seated when the user goes to their Space.
  @Test("A restore that only deferred is not ineffective")
  func allDeferredIsNotIneffective() {
    let report = RestoreReport(
      kind: .displayChange, topologyLabel: "Desk", deferred: 6, duration: 0.1
    )
    #expect(!report.wasIneffective)
  }

  @Test("A report survives a round trip through JSON")
  func codableRoundTrip() throws {
    let report = RestoreReport(
      kind: .manual, topologyLabel: "Desk", placed: 2, duration: 1
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(report)
    let decoded = try decoder.decode(RestoreReport.self, from: data)
    #expect(decoded.kind == .manual)
    #expect(decoded.topologyLabel == "Desk")
    #expect(decoded.placed == 2)
    #expect(decoded.duration == 1)
  }
}

@Suite("Receipts decoding")
struct ReceiptsDecodingTests {
  private func decode(_ json: String) throws -> Receipts {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Receipts.self, from: Data(json.utf8))
  }

  /// A receipts file written before the counters were renamed, and before the
  /// scene feature was removed. Everything still recognisable has to survive.
  @Test("An older receipts file keeps the counters it still has")
  func olderFileIsNotDiscarded() throws {
    let receipts = try decode("""
      {
        "snapshotsTaken": 6811,
        "restores": 96,
        "windowsMoved": 235,
        "windowsFailed": 0,
        "scenesApplied": 0,
        "lastReport": {
          "kind": "displayChange",
          "at": "2026-09-02T07:41:55Z",
          "topologyLabel": "Built-in Retina Display + DELL U3219Q",
          "placed": 0,
          "retried": 0,
          "failed": 0,
          "missing": 1,
          "launched": 0,
          "duration": 0.057
        }
      }
      """)
    #expect(receipts.restores == 96)
    #expect(receipts.windowsMoved == 235)
    #expect(receipts.lastReport?.missing == 1)
    #expect(receipts.lastReport?.wasIneffective == true)
    // Counted a different thing under the old name, so it starts again rather
    // than carrying a number that no longer means anything.
    #expect(receipts.layoutWrites == 0)
  }

  @Test("An empty object decodes to zeroed counters rather than failing")
  func emptyObjectDecodes() throws {
    #expect(try decode("{}") == Receipts())
  }

  @Test("A report naming a kind this build no longer has is dropped, not fatal")
  func unknownKindDropsOnlyTheReport() throws {
    let receipts = try decode("""
      {"restores": 4, "lastReport": {"kind": "scene", "at": "2026-09-02T07:41:55Z",
       "topologyLabel": "Desk", "placed": 1, "retried": 0, "failed": 0,
       "missing": 0, "duration": 1}}
      """)
    #expect(receipts.restores == 4)
    #expect(receipts.lastReport == nil)
  }
}

@Suite("Deferred vs missing")
struct DeferredClassificationTests {
  private let laptop = DisplayInfo(
    id: "laptop", name: "Built-in", bounds: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    isMain: true
  )

  private func snapshot(_ name: String, id: UInt32) -> WindowSnapshot {
    WindowSnapshot(
      bundleID: "com.example.\(name)",
      appName: name,
      windowID: id,
      title: name,
      ordinal: 0,
      frame: CGRect(x: 20, y: 20, width: 900, height: 700),
      display: laptop
    )
  }

  /// The distinction the Space support rests on. Neither snapshot matches a live
  /// window - there are none - but one of them still exists in the window server,
  /// so it is waiting rather than lost.
  @Test("An unmatched window that still exists is deferred, not missing")
  func existingUnmatchedIsDeferred() {
    let outcome = RestoreEngine.restore(
      windows: [snapshot("kitty", id: 11), snapshot("ghost", id: 12)],
      topology: Topology(displays: [laptop]),
      kind: .spaceChange,
      live: [],
      existing: [11]
    )
    #expect(outcome.report.deferred == 1)
    #expect(outcome.report.missing == 1)
  }

  /// And the consequence: a restore whose windows are all on other Spaces has
  /// done its job, so it neither reads as a failure nor earns retry passes.
  @Test("A restore that only deferred is not a failure")
  func allDeferredIsNotAFailure() {
    let outcome = RestoreEngine.restore(
      windows: [snapshot("kitty", id: 11), snapshot("zed", id: 12)],
      topology: Topology(displays: [laptop]),
      kind: .spaceChange,
      live: [],
      existing: [11, 12]
    )
    #expect(outcome.report.deferred == 2)
    #expect(outcome.report.missing == 0)
    #expect(!outcome.report.wasIneffective)
  }

  @Test("Windows whose apps are gone still read as missing")
  func vanishedWindowsAreMissing() {
    let outcome = RestoreEngine.restore(
      windows: [snapshot("kitty", id: 11)],
      topology: Topology(displays: [laptop]),
      kind: .manual,
      live: [],
      existing: []
    )
    #expect(outcome.report.missing == 1)
    #expect(outcome.report.wasIneffective)
  }
}
