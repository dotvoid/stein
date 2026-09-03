import CoreGraphics
import Foundation

/// Identifies a window well enough to follow it from one tick to the next.
///
/// A much smaller problem than the one `WindowMatcher` solves. That has to
/// recognise a window across a restart, from a description written days ago.
/// This only has to recognise it two seconds later, in the same session, where
/// the window number is present and exact.
public struct WindowKey: Hashable, Sendable {
  public var bundleID: String
  public var windowID: UInt32?
  /// Used only when the window has no number of its own.
  public var fallback: String

  public init(_ snapshot: WindowSnapshot) {
    self.init(
      bundleID: snapshot.bundleID,
      windowID: snapshot.windowID,
      ordinal: snapshot.ordinal,
      title: snapshot.title
    )
  }

  public init(_ identity: WindowIdentity) {
    self.init(
      bundleID: identity.bundleID,
      windowID: identity.windowID,
      ordinal: identity.ordinal,
      title: identity.title
    )
  }

  private init(bundleID: String, windowID: UInt32?, ordinal: Int, title: String) {
    self.bundleID = bundleID
    self.windowID = windowID
    fallback = windowID == nil ? "\(ordinal)|\(title)" : ""
  }
}

/// Decides which window positions the user is answerable for.
///
/// This is the distinction the whole app turns on, and getting it wrong is what
/// makes a layout restorer eat layouts. A window that *the user moved* records a
/// preference. A window that *macOS moved* records an accident - and the two are
/// indistinguishable if you only look at where the windows are now, which is why
/// every heuristic over the final positions eventually guesses wrong.
///
/// They are easy to tell apart while it happens, though, and Stein is watching
/// while it happens. Two facts settle it: what the desk looked like a moment ago,
/// and whether a human was here in between. A window that changed position with
/// nobody at the keyboard was not moved, it was *displaced*, and displacement is
/// not authorship. So its remembered position is left exactly as it was.
///
/// The consequence is the useful part. When a display comes back and its windows
/// are still piled on the laptop screen, nothing about that pile is authored:
/// every window sits where macOS put it, and the user has touched none of them.
/// So there is nothing to write, the remembered layout survives untouched, and it
/// survives for as long as the pile does - no timer, no threshold, and nothing to
/// ask the user. Drag one window out of the pile and that one window is authored,
/// which is exactly right, because that one window is the only one you chose.
///
/// Two things are deliberately *not* conclusions, and both were bugs before they
/// were rules. A window Stein has never measured is baselined rather than
/// credited to the user, so first sight of a Space cannot overwrite what is
/// already remembered about it. And a window that has left view is checked
/// against what exists before it is called closed, because most windows on other
/// Spaces are invisible to the Accessibility API and a Space switch would
/// otherwise read as the user closing everything they walked away from.
public struct WindowLedger {
  public struct Verdict: Equatable, Sendable {
    /// Windows whose current placement the user is responsible for.
    public var authored: [WindowSnapshot] = []
    /// Windows that are gone, and that the user was here to close.
    public var closed: [WindowSnapshot] = []
    /// Windows that moved with nobody here to move them. Reported for the
    /// diagnostics, and deliberately not acted on.
    public var displaced: [WindowSnapshot] = []
    /// Windows the layout has no opinion about yet, taken at face value.
    ///
    /// Not decided by the ledger - it has no way to know what is on file - so
    /// this is filled in from `LayoutSnapshot.unknownWindows(among:)` before the
    /// verdict is applied.
    public var adopted: [WindowSnapshot] = []

    public var hasChanges: Bool {
      !authored.isEmpty || !closed.isEmpty || !adopted.isEmpty
    }

    public init(
      authored: [WindowSnapshot] = [],
      closed: [WindowSnapshot] = [],
      displaced: [WindowSnapshot] = [],
      adopted: [WindowSnapshot] = []
    ) {
      self.authored = authored
      self.closed = closed
      self.displaced = displaced
      self.adopted = adopted
    }
  }

  /// One window as of the last measurement.
  private struct Sighting {
    /// Where it was, or `nil` when it existed but could not be measured -
    /// on another Space, so present but not comparable.
    var snapshot: WindowSnapshot?
  }

  private var known: [WindowKey: Sighting] = [:]
  private var seeded = false

  public init() {}

  public var hasBaseline: Bool { seeded }

  /// Takes the desk as the starting point without drawing any conclusion from it.
  ///
  /// Used after a display change, where the first measurement is the aftermath of
  /// something macOS did and says nothing about what the user wants.
  public mutating func seed(_ windows: [WindowSnapshot]) {
    known = index(windows)
    seeded = true
  }

  public mutating func reset() {
    known = [:]
    seeded = false
  }

  /// Compares the desk against the last measurement and splits the differences
  /// into the ones that count and the ones that do not.
  ///
  /// `existing` is every window number alive anywhere, from
  /// `WindowScanner.allWindowIDs()`. It answers the one question the visible desk
  /// cannot: a remembered window that is not in view has either been closed or is
  /// simply on another Space, and those call for opposite responses.
  public mutating func observe(
    _ windows: [WindowSnapshot],
    existing: Set<CGWindowID> = [],
    userWasActive: Bool
  ) -> Verdict {
    let before = known
    known = index(windows)
    guard seeded else {
      seeded = true
      return Verdict()
    }

    var verdict = Verdict()
    var seen = Set<WindowKey>()

    for window in windows {
      let key = WindowKey(window)
      seen.insert(key)
      // A window Stein has not measured before establishes its own baseline and
      // nothing more, whether it was just opened or just arrived from a Space
      // that could not be seen. Where it happens to be is not evidence anybody
      // put it there - and if the layout has no opinion about it, adoption writes
      // the position down without pretending it was a choice.
      guard let previousFrame = before[key]?.snapshot?.frame else { continue }
      // Standing still says nothing either way, and says it very often: on an
      // idle desk this is every window.
      guard !Geometry.matches(previousFrame, window.frame) else { continue }
      append(window, to: &verdict, authored: userWasActive)
    }

    for (key, sighting) in before where !seen.contains(key) {
      guard let window = sighting.snapshot else { continue }
      // Out of sight is not gone. Whether the Accessibility API mentions a
      // window on another Space is up to the app, so its absence from view is no
      // evidence either way and has to be checked against the list of what
      // exists before anyone concludes the user closed it.
      if let id = key.windowID, existing.contains(id) { continue }
      // And a window vanishing while nobody is here is a window Stein could not
      // see, not a window the user closed. The lock screen hides almost the whole
      // desk that way, and forgetting a layout because of it is how a full desk
      // comes to be remembered as one window.
      if userWasActive {
        verdict.closed.append(window)
      } else {
        verdict.displaced.append(window)
      }
    }

    return verdict
  }

  private func append(_ window: WindowSnapshot, to verdict: inout Verdict, authored: Bool) {
    if authored {
      verdict.authored.append(window)
    } else {
      verdict.displaced.append(window)
    }
  }

  private func index(_ windows: [WindowSnapshot]) -> [WindowKey: Sighting] {
    Dictionary(
      windows.map { (WindowKey($0), Sighting(snapshot: $0)) },
      uniquingKeysWith: { first, _ in first }
    )
  }
}
