import CoreGraphics
import Foundation
import Testing
@testable import SteinCore

@Suite("Store")
struct StoreTests {
  /// A realistic fingerprint. Layouts are filed under the current identity rule
  /// and anything else is discarded on load, so fixtures have to look real.
  private func fp(_ name: String) -> String {
    "\(Topology.fingerprintVersion)|\(name):3440x1440"
  }

  private func temporaryStore() -> Store {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("stein-tests-\(UUID().uuidString)")
    return Store(directory: directory)
  }

  private func layout(
    fingerprint: String,
    at date: Date = Date(),
    titles: [String] = ["window"]
  ) -> LayoutSnapshot {
    let display = DisplayInfo(
      id: "d", name: "D", bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), isMain: true
    )
    return LayoutSnapshot(
      fingerprint: fingerprint,
      topologyLabel: "Desk",
      capturedAt: date,
      windows: titles.enumerated().map { index, title in
        WindowSnapshot(
          bundleID: "com.example.app",
          appName: "App",
          windowID: UInt32(index + 1),
          title: title,
          ordinal: index,
          frame: CGRect(x: 0, y: 0, width: 400, height: 300),
          display: display
        )
      }
    )
  }

  @Test("A layout comes back out again, filed under its desk")
  func remembersAndReturnsLayouts() {
    let store = temporaryStore()
    #expect(store.remember(layout(fingerprint: fp("desk-a"))))
    #expect(store.layout(for: fp("desk-a"))?.windows.count == 1)
    #expect(store.layout(for: fp("desk-b")) == nil)
  }

  @Test("Filing an unchanged layout writes nothing")
  func identicalLayoutIsNotRewritten() {
    let store = temporaryStore()
    let snapshot = layout(fingerprint: fp("desk-a"), at: Date(timeIntervalSince1970: 100))
    #expect(store.remember(snapshot))
    let again = layout(fingerprint: fp("desk-a"), at: Date(timeIntervalSince1970: 500))
    #expect(!store.remember(again))
    // The original capture time is kept, so an idle desk does not look busy.
    #expect(store.layout(for: fp("desk-a"))?.capturedAt == Date(timeIntervalSince1970: 100))
  }

  @Test("A moved window is a change and is written")
  func changedLayoutIsWritten() {
    let store = temporaryStore()
    #expect(store.remember(layout(fingerprint: fp("desk-a"), titles: ["one"])))
    #expect(store.remember(layout(fingerprint: fp("desk-a"), titles: ["one", "two"])))
    #expect(store.layout(for: fp("desk-a"))?.windows.count == 2)
  }

  @Test("Layouts persist across a restart")
  func layoutsSurviveRelaunch() {
    let store = temporaryStore()
    store.remember(layout(fingerprint: fp("desk-a")))
    let reopened = Store(directory: store.directory)
    #expect(reopened.layout(for: fp("desk-a")) != nil)
  }

  @Test("Only the most recent desks are kept")
  func oldestDesksArePruned() {
    let store = temporaryStore()
    let total = Store.maximumRememberedDesks + 5
    for index in 0..<total {
      store.remember(
        layout(
          fingerprint: fp("desk-\(index)"),
          at: Date(timeIntervalSince1970: Double(index)),
          titles: ["w\(index)"]
        )
      )
    }
    #expect(store.rememberedDesks.count == Store.maximumRememberedDesks)
    #expect(store.layout(for: fp("desk-0")) == nil)
    #expect(store.layout(for: fp("desk-\(total - 1)")) != nil)
  }

  @Test("Remembered desks are listed newest first")
  func desksAreSortedByRecency() {
    let store = temporaryStore()
    store.remember(layout(fingerprint: fp("old"), at: Date(timeIntervalSince1970: 10), titles: ["a"]))
    store.remember(layout(fingerprint: fp("new"), at: Date(timeIntervalSince1970: 20), titles: ["b"]))
    #expect(store.rememberedDesks.first?.fingerprint == fp("new"))
  }

  @Test("Receipts accumulate and survive a restart")
  func receiptsAccumulate() {
    let store = temporaryStore()
    store.recordLayoutWrite()
    store.record(
      RestoreReport(kind: .displayChange, topologyLabel: "Desk", placed: 9, retried: 2, failed: 1)
    )
    store.record(RestoreReport(kind: .manual, topologyLabel: "Desk", placed: 3))
    let receipts = Store(directory: store.directory).receipts
    #expect(receipts.layoutWrites == 1)
    #expect(receipts.restores == 2)
    #expect(receipts.windowsMoved == 14)
    #expect(receipts.windowsFailed == 1)
    #expect(receipts.lastReport?.placed == 3)
  }

  @Test("Layouts filed under an older fingerprint rule are discarded on load")
  func foreignVersionsAreDiscarded() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("stein-tests-\(UUID().uuidString)")
    let file = JSONFile<[String: LayoutSnapshot]>(
      url: directory.appendingPathComponent("layouts.json")
    )
    let current = Topology.fingerprintVersion + "|ABC:3440x1440"
    file.save([
      "v0|ABC@0,0:3440x1440": layout(fingerprint: "v0|ABC@0,0:3440x1440", titles: ["old"]),
      current: layout(fingerprint: current, titles: ["new"])
    ])

    let store = Store(directory: directory)
    #expect(store.rememberedDesks.count == 1)
    #expect(store.layout(for: current)?.windows.first?.title == "new")
    // And the pruning is written through, not just applied in memory.
    #expect(Store(directory: directory).rememberedDesks.count == 1)
  }

  @Test("A missing store starts empty instead of failing")
  func missingStoreIsEmpty() {
    let store = temporaryStore()
    #expect(store.rememberedDesks.isEmpty)
    #expect(store.receipts == Receipts())
  }
}

@Suite("Abandoned temporary files")
struct JSONFileSweepTests {
  private func temporaryDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("stein-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func write(_ name: String, in directory: URL, age: TimeInterval) -> URL {
    let url = directory.appendingPathComponent(name)
    try? Data("{}".utf8).write(to: url)
    try? FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-age)],
      ofItemAtPath: url.path
    )
    return url
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  /// The debris this cleans up: a write interrupted between "write the sibling"
  /// and "swap it into place" leaves the sibling behind forever.
  @Test("A stale temporary is swept when the file is opened")
  func staleTemporaryIsRemoved() {
    let directory = temporaryDirectory()
    let stale = write("layouts.json.tmp-2941166626", in: directory, age: 3600)
    _ = JSONFile<[String: Int]>(url: directory.appendingPathComponent("layouts.json"))
    #expect(!exists(stale))
  }

  /// A write under way in another process is none of our business.
  @Test("A temporary young enough to be in use is left alone")
  func freshTemporaryIsKept() {
    let directory = temporaryDirectory()
    let fresh = write("layouts.json.tmp-17", in: directory, age: 1)
    _ = JSONFile<[String: Int]>(url: directory.appendingPathComponent("layouts.json"))
    #expect(exists(fresh))
  }

  @Test("Only this file's temporaries are swept")
  func otherFilesAreUntouched() {
    let directory = temporaryDirectory()
    let mine = write("layouts.json.tmp-1", in: directory, age: 3600)
    let theirs = write("receipts.json.tmp-2", in: directory, age: 3600)
    let real = write("receipts.json", in: directory, age: 3600)
    _ = JSONFile<[String: Int]>(url: directory.appendingPathComponent("layouts.json"))
    #expect(!exists(mine))
    #expect(exists(theirs))
    #expect(exists(real))
  }

  @Test("The real file is never mistaken for a temporary")
  func realFileSurvives() {
    let directory = temporaryDirectory()
    let real = write("layouts.json", in: directory, age: 86_400)
    let file = JSONFile<[String: Int]>(url: directory.appendingPathComponent("layouts.json"))
    #expect(exists(real))
    #expect(file.load() != nil)
  }

  @Test("A missing directory is not an error")
  func missingDirectoryIsFine() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("stein-tests-absent-\(UUID().uuidString)")
    let file = JSONFile<[String: Int]>(url: directory.appendingPathComponent("layouts.json"))
    #expect(file.load() == nil)
    // And saving still creates what it needs.
    file.save(["a": 1])
    #expect(file.load() == ["a": 1])
  }
}
