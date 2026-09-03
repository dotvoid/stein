import CoreGraphics
import Foundation

/// Everything the matcher is allowed to know about a window that exists right now.
public struct WindowIdentity: Equatable, Sendable {
  public var bundleID: String
  public var title: String
  public var ordinal: Int
  public var windowID: UInt32?
  public var frame: CGRect

  public init(
    bundleID: String,
    title: String,
    ordinal: Int,
    windowID: UInt32?,
    frame: CGRect
  ) {
    self.bundleID = bundleID
    self.title = title
    self.ordinal = ordinal
    self.windowID = windowID
    self.frame = frame
  }
}

/// Pairs live windows with the snapshots that describe them.
///
/// This is the problem every layout restorer actually has to solve. macOS exposes
/// no public, persistent window identity, so "is this the same window I saw ten
/// minutes ago?" has to be answered from evidence: window number first, then
/// title, then position among its siblings, then where it happens to be sitting.
public enum WindowMatcher {
  public struct Pairing<Live> {
    public var live: Live
    public var identity: WindowIdentity
    public var snapshot: WindowSnapshot
    public var score: Int
  }

  public struct Result<Live> {
    public var pairs: [Pairing<Live>]
    public var unmatchedSnapshots: [WindowSnapshot]
    public var unmatchedLive: [Live]
  }

  struct Candidate {
    var liveIndex: Int
    var snapshotIndex: Int
    var score: Int
  }

  /// Below this, the evidence is too thin to act on.
  ///
  /// Same-app-and-nothing-else scores 1, and pairing on that alone means moving
  /// one window into another window's remembered slot - the single most visible
  /// way a layout restorer can be wrong. Leaving a window alone is always
  /// recoverable; putting it somewhere it never was is not. The floor clears
  /// ordinal agreement (26), any real title agreement, and a window still sitting
  /// within roughly 100 points of where it was.
  public static let minimumScore = 12

  static let windowNumberScore = 1000
  static let exactTitleScore = 200
  static let titleSimilarityScore = 120
  static let ordinalScore = 25
  static let positionScore = 15
  /// Below this, a title resemblance is noise rather than evidence.
  ///
  /// Edit distance always returns *some* similarity between two strings, and
  /// counting a 9% resemblance as partial proof is how a window ends up in another
  /// window's slot. Titles drift by suffixes and markers, not beyond recognition.
  static let minimumTitleSimilarity = 0.35

  /// `nil` when the two cannot possibly be the same window.
  public static func score(live: WindowIdentity, snapshot: WindowSnapshot) -> Int? {
    guard live.bundleID == snapshot.bundleID else { return nil }

    // A matching window number is proof, not evidence. Everything else is a guess.
    if let a = live.windowID, let b = snapshot.windowID, a == b {
      return windowNumberScore
    }
    // Two different window numbers from the same session are proof of the opposite.
    if let a = live.windowID, let b = snapshot.windowID, a != b, b != 0, a != 0 {
      return nil
    }

    var score = 1

    if !live.title.isEmpty, live.title == snapshot.title {
      score += exactTitleScore
    } else if !live.title.isEmpty, !snapshot.title.isEmpty {
      let similarity = titleSimilarity(live.title, snapshot.title)
      if similarity >= minimumTitleSimilarity {
        score += Int(Double(titleSimilarityScore) * similarity)
      }
    }

    if live.ordinal == snapshot.ordinal {
      score += ordinalScore
    }

    let drift = Geometry.distance(from: live.frame.origin, to: snapshot.frame.origin)
    if drift < 4 {
      score += positionScore
    } else if drift < 400 {
      score += Int(Double(positionScore) * (1 - drift / 400))
    }

    return score
  }

  public static func match<Live>(
    live: [(Live, WindowIdentity)],
    snapshots: [WindowSnapshot]
  ) -> Result<Live> {
    var candidates: [Candidate] = []
    for (liveIndex, entry) in live.enumerated() {
      for (snapshotIndex, snapshot) in snapshots.enumerated() {
        guard let score = score(live: entry.1, snapshot: snapshot),
              score >= minimumScore else { continue }
        candidates.append(
          Candidate(liveIndex: liveIndex, snapshotIndex: snapshotIndex, score: score)
        )
      }
    }

    // Best evidence wins first; ties resolve deterministically so a restore is
    // reproducible rather than dependent on enumeration order.
    candidates.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.liveIndex != $1.liveIndex { return $0.liveIndex < $1.liveIndex }
      return $0.snapshotIndex < $1.snapshotIndex
    }

    var usedLive = Set<Int>()
    var usedSnapshots = Set<Int>()
    var pairs: [Pairing<Live>] = []

    for candidate in candidates {
      guard !usedLive.contains(candidate.liveIndex),
            !usedSnapshots.contains(candidate.snapshotIndex) else { continue }
      usedLive.insert(candidate.liveIndex)
      usedSnapshots.insert(candidate.snapshotIndex)
      let entry = live[candidate.liveIndex]
      pairs.append(
        Pairing(
          live: entry.0,
          identity: entry.1,
          snapshot: snapshots[candidate.snapshotIndex],
          score: candidate.score
        )
      )
    }

    return Result(
      pairs: pairs,
      unmatchedSnapshots: snapshots.enumerated()
        .filter { !usedSnapshots.contains($0.offset) }
        .map(\.element),
      unmatchedLive: live.enumerated()
        .filter { !usedLive.contains($0.offset) }
        .map(\.element.0)
    )
  }

  /// 0...1 similarity, edit distance over the longer string.
  ///
  /// Titles drift constantly - an edited document gains a marker, a browser tab
  /// changes, a terminal shows a different path - so exactness cannot be required.
  static func titleSimilarity(_ a: String, _ b: String) -> Double {
    let left = Array(a.lowercased().prefix(80))
    let right = Array(b.lowercased().prefix(80))
    if left.isEmpty || right.isEmpty { return 0 }
    if left == right { return 1 }

    var previous = Array(0...right.count)
    var current = [Int](repeating: 0, count: right.count + 1)

    for i in 1...left.count {
      current[0] = i
      for j in 1...right.count {
        let cost = left[i - 1] == right[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }

    let distance = Double(previous[right.count])
    let longest = Double(max(left.count, right.count))
    return max(0, 1 - distance / longest)
  }
}
