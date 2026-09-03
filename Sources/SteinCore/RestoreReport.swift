import Foundation

/// What a restore actually did. Shown to the user verbatim - a restorer that
/// silently "did something" is indistinguishable from one that did nothing.
public struct RestoreReport: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case displayChange
    case spaceChange
    case manual
    case undo
  }

  public var kind: Kind
  public var at: Date
  public var topologyLabel: String
  /// Windows already sitting exactly where the layout wants them.
  ///
  /// Counted apart from `placed` because "nothing needed doing" and "I moved
  /// fourteen windows" are different events, and a restore that runs on every
  /// Space switch had better be able to tell the user which one just happened.
  public var unchanged: Int
  /// Windows moved and verified on the first attempt.
  public var placed: Int
  /// Windows that needed the size-then-position retry before they held still.
  public var retried: Int
  /// Windows that refused to move even after the retry.
  public var failed: Int
  /// Snapshot entries with no live window to apply them to - the app is closed,
  /// or its window could not be identified with enough confidence to move.
  public var missing: Int
  /// Windows that exist on another Space, and were deliberately left alone until
  /// the user goes there. Not a failure, and not missing.
  public var deferred: Int
  public var duration: TimeInterval

  public init(
    kind: Kind,
    at: Date = Date(),
    topologyLabel: String,
    unchanged: Int = 0,
    placed: Int = 0,
    retried: Int = 0,
    failed: Int = 0,
    missing: Int = 0,
    deferred: Int = 0,
    duration: TimeInterval = 0
  ) {
    self.kind = kind
    self.at = at
    self.topologyLabel = topologyLabel
    self.unchanged = unchanged
    self.placed = placed
    self.retried = retried
    self.failed = failed
    self.missing = missing
    self.deferred = deferred
    self.duration = duration
  }

  /// Decoded leniently, for the same reason `Receipts` is: this record is
  /// persisted, it gains a counter whenever Stein learns to distinguish one more
  /// outcome, and throwing away the last report because it predates the newest
  /// counter would lose the one thing the user is shown about it.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(Kind.self, forKey: .kind)
    at = try container.decode(Date.self, forKey: .at)
    topologyLabel = try container.decode(String.self, forKey: .topologyLabel)
    duration = (try? container.decodeIfPresent(TimeInterval.self, forKey: .duration)) ?? 0
    func count(_ key: CodingKeys) -> Int {
      (try? container.decodeIfPresent(Int.self, forKey: key)) ?? 0
    }
    unchanged = count(.unchanged)
    placed = count(.placed)
    retried = count(.retried)
    failed = count(.failed)
    missing = count(.missing)
    deferred = count(.deferred)
  }

  public var totalMoved: Int { placed + retried }

  /// Snapshot entries the restore had an opinion about, moved or not.
  public var considered: Int { unchanged + placed + retried + failed + missing + deferred }

  /// True when the restore was given work to do and achieved nothing.
  ///
  /// Worth a name of its own because `failed == 0` makes a restore look like a
  /// success even when it moved no windows at all. The common cause is a layout
  /// that no longer describes any live window - typically because the layout on
  /// file *is* the pile macOS left behind, so putting it back is a no-op. A
  /// learner that treats that desk as the truth will file the pile again and the
  /// good layout is gone, which is exactly how a working restorer quietly turns
  /// into one that does nothing.
  ///
  /// A desk that needed no work is not ineffective, nor is one whose windows are
  /// all waiting on another Space. An undo is exempt too: it only ever replays
  /// frames Stein itself just moved away from, so a window that has since closed
  /// is expected rather than a symptom.
  public var wasIneffective: Bool {
    guard kind != .undo else { return false }
    guard totalMoved == 0, unchanged == 0 else { return false }
    return failed + missing > 0
  }

  public var title: String {
    switch kind {
    case .spaceChange: return topologyLabel
    case .manual: return "Layout restored"
    case .undo: return "Restore undone"
    case .displayChange: return topologyLabel
    }
  }

  /// One line, plain language, no marketing: "14 windows, 1 retried, 0.8s".
  public var summary: String {
    var parts: [String] = ["\(totalMoved) window\(totalMoved == 1 ? "" : "s")"]
    if unchanged > 0 { parts.append("\(unchanged) already right") }
    if retried > 0 { parts.append("\(retried) retried") }
    if failed > 0 { parts.append("\(failed) failed") }
    if missing > 0 { parts.append("\(missing) not found") }
    if deferred > 0 { parts.append("\(deferred) on other Spaces") }
    if wasIneffective { parts.append("nothing moved") }
    parts.append(String(format: "%.1fs", duration))
    return parts.joined(separator: ", ")
  }
}

/// Lifetime counters. Same idea as the report, over a longer window.
public struct Receipts: Codable, Equatable, Sendable {
  /// Writes to the remembered layouts. One per batch of authored changes, not
  /// one per measurement - the learner measures constantly and writes rarely.
  public var layoutWrites: Int = 0
  public var restores: Int = 0
  public var windowsMoved: Int = 0
  public var windowsFailed: Int = 0
  public var lastReport: RestoreReport?

  public init() {}

  /// Decoded leniently, field by field.
  ///
  /// Swift's synthesized decoder ignores property defaults and throws on the
  /// first missing key, so adding or renaming one counter would discard the whole
  /// file - every counter *and* the last report - the next time Stein started.
  /// A counters file is exactly the thing that keeps gaining fields, so it reads
  /// whatever it recognises and leaves the rest at zero.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    layoutWrites = (try? container.decodeIfPresent(Int.self, forKey: .layoutWrites)) ?? 0
    restores = (try? container.decodeIfPresent(Int.self, forKey: .restores)) ?? 0
    windowsMoved = (try? container.decodeIfPresent(Int.self, forKey: .windowsMoved)) ?? 0
    windowsFailed = (try? container.decodeIfPresent(Int.self, forKey: .windowsFailed)) ?? 0
    // A report written by an older build may name a restore kind this one no
    // longer has, and losing the last report is better than losing the file.
    lastReport = try? container.decodeIfPresent(RestoreReport.self, forKey: .lastReport)
  }

  public mutating func recordWrite() {
    layoutWrites += 1
  }

  public mutating func record(_ report: RestoreReport) {
    restores += 1
    windowsMoved += report.totalMoved
    windowsFailed += report.failed
    lastReport = report
  }
}
