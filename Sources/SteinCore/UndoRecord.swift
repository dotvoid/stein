import Foundation

/// Where the windows of the last restore were sitting before Stein touched them.
///
/// Small enough to look trivial, and it has been wrong twice, so it lives here
/// where a test can reach it rather than inside the coordinator.
///
/// Two rules, both learned the hard way:
///
/// - A restore that moved nothing contributes nothing *and clears nothing*.
///   Stein restores on every Space change, and almost every one of those finds
///   the windows already in place - so a record that reset on each restore was
///   disarmed seconds after a real restore armed it.
/// - Within one restore, the earliest sighting of each window wins. A restore is
///   several passes: an early optimistic one and a confirming one, plus retries
///   for anything that refused. Only the first pass saw where a window started,
///   and that is the position undo has to return it to.
public struct UndoRecord: Equatable, Sendable {
  private var found: [WindowSnapshot] = []
  /// The restore this record belongs to. A new one starts a new record.
  private var episode = -1

  public init() {}

  public var windows: [WindowSnapshot] { found }
  public var isEmpty: Bool { found.isEmpty }

  public mutating func record(_ moved: [WindowSnapshot], episode: Int) {
    guard !moved.isEmpty else { return }
    if self.episode != episode {
      found = []
      self.episode = episode
    }
    for window in moved where !found.contains(where: { $0.isSameWindow(as: window) }) {
      found.append(window)
    }
  }

  /// Undo is one-shot on purpose. Offering to undo an undo turns one clear action
  /// into a toggle nobody can keep track of.
  public mutating func clear() {
    found = []
    episode = -1
  }
}

extension WindowSnapshot {
  /// Same window, without asking where it is - so a window can be recognised as
  /// one already recorded even though the whole point is that it has moved.
  func isSameWindow(as other: WindowSnapshot) -> Bool {
    bundleID == other.bundleID && windowID == other.windowID && ordinal == other.ordinal
  }
}
