import CoreGraphics
import Foundation
import Testing
@testable import SteinCore

@Suite("Window matching")
struct WindowMatcherTests {
  private let display = DisplayInfo(
    id: "wide",
    name: "Ultrawide",
    bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    isMain: true
  )

  private func snapshot(
    bundleID: String = "com.example.editor",
    windowID: UInt32? = nil,
    title: String,
    ordinal: Int = 0,
    frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
  ) -> WindowSnapshot {
    WindowSnapshot(
      bundleID: bundleID,
      appName: "Editor",
      windowID: windowID,
      title: title,
      ordinal: ordinal,
      frame: frame,
      display: display
    )
  }

  private func live(
    bundleID: String = "com.example.editor",
    windowID: UInt32? = nil,
    title: String,
    ordinal: Int = 0,
    frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
  ) -> WindowIdentity {
    WindowIdentity(
      bundleID: bundleID,
      title: title,
      ordinal: ordinal,
      windowID: windowID,
      frame: frame
    )
  }

  @Test("Windows from different apps are never the same window")
  func differentAppsNeverMatch() {
    #expect(
      WindowMatcher.score(
        live: live(bundleID: "com.apple.Safari", title: "Docs"),
        snapshot: snapshot(bundleID: "com.example.editor", title: "Docs")
      ) == nil
    )
  }

  @Test("A matching window number outranks everything else")
  func windowNumberIsDecisive() {
    let score = WindowMatcher.score(
      live: live(windowID: 900, title: "completely different", ordinal: 7),
      snapshot: snapshot(windowID: 900, title: "notes.md", ordinal: 0)
    )
    #expect(score == WindowMatcher.windowNumberScore)
  }

  @Test("Two different window numbers rule the pairing out entirely")
  func conflictingWindowNumbersRejected() {
    #expect(
      WindowMatcher.score(
        live: live(windowID: 901, title: "notes.md"),
        snapshot: snapshot(windowID: 900, title: "notes.md")
      ) == nil
    )
  }

  @Test("Without window numbers, an exact title beats a similar one")
  func exactTitleBeatsSimilar() {
    let exact = WindowMatcher.score(
      live: live(title: "notes.md"),
      snapshot: snapshot(title: "notes.md")
    )
    let similar = WindowMatcher.score(
      live: live(title: "notes.md — edited"),
      snapshot: snapshot(title: "notes.md")
    )
    #expect(exact! > similar!)
    #expect(similar! > 1)
  }

  @Test("Untitled windows still match on position among their siblings")
  func ordinalCarriesUntitledWindows() {
    let sameSlot = WindowMatcher.score(
      live: live(title: "", ordinal: 2),
      snapshot: snapshot(title: "", ordinal: 2)
    )
    let otherSlot = WindowMatcher.score(
      live: live(title: "", ordinal: 5),
      snapshot: snapshot(title: "", ordinal: 2)
    )
    #expect(sameSlot! > otherSlot!)
  }

  @Test("A window that has not moved scores above one on the far side of the screen")
  func positionBreaksTies() {
    let stationary = WindowMatcher.score(
      live: live(title: "", ordinal: 9, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
      snapshot: snapshot(title: "", ordinal: 0)
    )
    let moved = WindowMatcher.score(
      live: live(title: "", ordinal: 9, frame: CGRect(x: 2600, y: 800, width: 800, height: 600)),
      snapshot: snapshot(title: "", ordinal: 0)
    )
    #expect(stationary! > moved!)
  }

  @Test("Each window is claimed once, by its best evidence")
  func assignmentIsOneToOne() {
    let snapshots = [
      snapshot(windowID: 10, title: "left", ordinal: 0),
      snapshot(windowID: 11, title: "right", ordinal: 1)
    ]
    // Reported in the opposite order, with titles that have since changed.
    let liveWindows = [
      ("b", live(windowID: 11, title: "right — modified", ordinal: 0)),
      ("a", live(windowID: 10, title: "left — modified", ordinal: 1))
    ]
    let result = WindowMatcher.match(live: liveWindows, snapshots: snapshots)
    #expect(result.pairs.count == 2)
    #expect(result.unmatchedLive.isEmpty)
    #expect(result.unmatchedSnapshots.isEmpty)
    let byName = Dictionary(uniqueKeysWithValues: result.pairs.map { ($0.live, $0.snapshot.title) })
    #expect(byName["a"] == "left")
    #expect(byName["b"] == "right")
  }

  @Test("A remembered window whose app is closed is reported as missing")
  func unmatchedSnapshotsAreReported() {
    let result = WindowMatcher.match(
      live: [("only", live(title: "kept"))],
      snapshots: [snapshot(title: "kept"), snapshot(bundleID: "com.apple.Safari", title: "gone")]
    )
    #expect(result.pairs.count == 1)
    #expect(result.unmatchedSnapshots.count == 1)
    #expect(result.unmatchedSnapshots.first?.title == "gone")
  }

  @Test("A window opened since the snapshot is left alone")
  func unmatchedLiveIsReported() {
    let result = WindowMatcher.match(
      live: [("known", live(title: "kept")), ("new", live(bundleID: "com.apple.Mail", title: "x"))],
      snapshots: [snapshot(title: "kept")]
    )
    #expect(result.pairs.count == 1)
    #expect(result.unmatchedLive == ["new"])
  }

  @Test("Matching the same input twice gives the same answer")
  func matchingIsDeterministic() {
    let snapshots = [snapshot(title: "one", ordinal: 0), snapshot(title: "two", ordinal: 1)]
    let liveWindows = [
      (0, live(title: "one", ordinal: 0)),
      (1, live(title: "one", ordinal: 1))
    ]
    let first = WindowMatcher.match(live: liveWindows, snapshots: snapshots)
    let second = WindowMatcher.match(live: liveWindows, snapshots: snapshots)
    #expect(first.pairs.map(\.live) == second.pairs.map(\.live))
    #expect(first.pairs.map(\.snapshot.title) == second.pairs.map(\.snapshot.title))
  }

  @Test("Title similarity scores identical, drifted and unrelated titles apart")
  func titleSimilarityBehaves() {
    #expect(WindowMatcher.titleSimilarity("notes.md", "notes.md") == 1)
    #expect(WindowMatcher.titleSimilarity("notes.md", "NOTES.MD") == 1)
    #expect(WindowMatcher.titleSimilarity("notes.md", "notes.md — edited") > 0.4)
    #expect(WindowMatcher.titleSimilarity("notes.md", "") == 0)
    #expect(WindowMatcher.titleSimilarity("aaaa", "bbbb") == 0)
  }
}

@Suite("Matching confidence")
struct MatchingConfidenceTests {
  private let display = DisplayInfo(
    id: "wide",
    name: "Ultrawide",
    bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    isMain: true
  )
  private let near = CGRect(x: 0, y: 0, width: 800, height: 600)
  private let far = CGRect(x: 2400, y: 800, width: 800, height: 600)

  private func snapshot(title: String, ordinal: Int, frame: CGRect) -> WindowSnapshot {
    WindowSnapshot(
      bundleID: "com.example.editor",
      appName: "Editor",
      windowID: nil,
      title: title,
      ordinal: ordinal,
      frame: frame,
      display: display
    )
  }

  private func live(title: String, ordinal: Int, frame: CGRect) -> WindowIdentity {
    WindowIdentity(
      bundleID: "com.example.editor",
      title: title,
      ordinal: ordinal,
      windowID: nil,
      frame: frame
    )
  }

  @Test("Sharing an app and nothing else is not enough to move a window")
  func weakEvidenceIsRefused() {
    let result = WindowMatcher.match(
      live: [("live", live(title: "zzzzzzzzzzzzzzzz", ordinal: 9, frame: far))],
      snapshots: [snapshot(title: "notes.md", ordinal: 0, frame: near)]
    )
    #expect(result.pairs.isEmpty)
    #expect(result.unmatchedLive == ["live"])
    #expect(result.unmatchedSnapshots.count == 1)
  }

  @Test("A faint title resemblance counts for nothing")
  func noiseTitlesScoreNothing() {
    let score = WindowMatcher.score(
      live: live(title: "an entirely different window", ordinal: 9, frame: far),
      snapshot: snapshot(title: "notes.md", ordinal: 0, frame: near)
    )
    #expect(score == 1)
    #expect(score! < WindowMatcher.minimumScore)
  }

  @Test("A drifted title still counts as evidence")
  func drifedTitlesStillMatch() {
    let result = WindowMatcher.match(
      live: [("live", live(title: "notes.md — edited", ordinal: 9, frame: far))],
      snapshots: [snapshot(title: "notes.md", ordinal: 0, frame: near)]
    )
    #expect(result.pairs.count == 1)
  }

  @Test("Untitled windows in the same slot are still matched")
  func ordinalAloneClearsTheFloor() {
    let result = WindowMatcher.match(
      live: [("live", live(title: "", ordinal: 3, frame: far))],
      snapshots: [snapshot(title: "", ordinal: 3, frame: near)]
    )
    #expect(result.pairs.count == 1)
  }

  @Test("A window that has not moved at all is matched even without a title")
  func stationaryWindowClearsTheFloor() {
    let result = WindowMatcher.match(
      live: [("live", live(title: "", ordinal: 9, frame: near))],
      snapshots: [snapshot(title: "", ordinal: 0, frame: near)]
    )
    #expect(result.pairs.count == 1)
  }
}
