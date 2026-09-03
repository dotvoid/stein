import CoreGraphics
import Foundation
import Testing
@testable import SteinCore

@Suite("Undo record")
struct UndoRecordTests {
  private let laptop = DisplayInfo(
    id: "laptop", name: "Built-in", bounds: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    isMain: true
  )

  private func window(_ name: String, id: UInt32, x: CGFloat) -> WindowSnapshot {
    WindowSnapshot(
      bundleID: "com.example.\(name)",
      appName: name,
      windowID: id,
      title: name,
      ordinal: 0,
      frame: CGRect(x: x, y: 20, width: 900, height: 700),
      display: laptop
    )
  }

  @Test("A restore that moved something is recorded")
  func recordsAMove() {
    var record = UndoRecord()
    record.record([window("chrome", id: 1, x: 10)], episode: 1)
    #expect(record.windows.count == 1)
    #expect(!record.isEmpty)
  }

  /// The bug that shipped twice. Stein restores on every Space change and almost
  /// all of those move nothing, so a record that reset per restore was wiped
  /// seconds after a real restore armed it.
  @Test("A restore that moved nothing leaves the record alone")
  func noOpRestoreDoesNotClear() {
    var record = UndoRecord()
    record.record([window("chrome", id: 1, x: 10)], episode: 1)
    record.record([], episode: 2)
    record.record([], episode: 3)
    #expect(record.windows.count == 1)
    #expect(record.windows.first?.frame.minX == 10)
  }

  /// A restore is several passes, and only the first saw where a window started.
  @Test("Within one restore the earliest sighting of a window wins")
  func earliestSightingWins() {
    var record = UndoRecord()
    record.record([window("chrome", id: 1, x: 10)], episode: 7)
    // A later pass in the same restore sees the window where the first pass put
    // it, which is not where undo should send it back to.
    record.record([window("chrome", id: 1, x: 500)], episode: 7)
    #expect(record.windows.count == 1)
    #expect(record.windows.first?.frame.minX == 10)
  }

  @Test("A later pass can still add a window the first pass did not reach")
  func laterPassAddsNewWindows() {
    var record = UndoRecord()
    record.record([window("chrome", id: 1, x: 10)], episode: 7)
    record.record([window("chrome", id: 1, x: 500), window("zed", id: 2, x: 30)], episode: 7)
    #expect(record.windows.count == 2)
    #expect(record.windows.first { $0.appName == "chrome" }?.frame.minX == 10)
    #expect(record.windows.first { $0.appName == "zed" }?.frame.minX == 30)
  }

  @Test("A new restore starts a new record")
  func newEpisodeReplaces() {
    var record = UndoRecord()
    record.record([window("chrome", id: 1, x: 10)], episode: 1)
    record.record([window("zed", id: 2, x: 30)], episode: 2)
    #expect(record.windows.count == 1)
    #expect(record.windows.first?.appName == "zed")
  }

  @Test("Undoing empties the record, so an undo cannot be undone")
  func clearIsOneShot() {
    var record = UndoRecord()
    record.record([window("chrome", id: 1, x: 10)], episode: 1)
    record.clear()
    #expect(record.isEmpty)
    // And the cleared record does not resurrect on the same episode number.
    record.record([], episode: 1)
    #expect(record.isEmpty)
  }
}
