import CoreGraphics
import Foundation

/// Where one window sat, recorded richly enough to find that window again later
/// and to place it sensibly even if its display comes back at a different size.
public struct WindowSnapshot: Codable, Equatable, Sendable {
  public var bundleID: String
  public var appName: String
  /// CGWindowID. Stable for the lifetime of the window, which covers the case
  /// Stein cares about most - unplug and replug without quitting anything.
  public var windowID: UInt32?
  public var title: String
  /// Position among that app's windows at capture time. The fallback identity
  /// when an app gives every window the same title (or no title at all).
  public var ordinal: Int
  public var displayID: String
  /// Absolute frame in global top-left-origin coordinates.
  public var frame: CGRect
  /// Frame relative to the host display's origin, so the same layout can be
  /// replayed onto a display that now lives elsewhere in the coordinate space.
  public var offsetInDisplay: CGPoint
  public var displaySize: CGSize
  public var fraction: FractionalFrame

  public init(
    bundleID: String,
    appName: String,
    windowID: UInt32?,
    title: String,
    ordinal: Int,
    frame: CGRect,
    display: DisplayInfo
  ) {
    self.bundleID = bundleID
    self.appName = appName
    self.windowID = windowID
    self.title = title
    self.ordinal = ordinal
    self.displayID = display.id
    self.frame = frame
    self.offsetInDisplay = CGPoint(
      x: frame.minX - display.bounds.minX,
      y: frame.minY - display.bounds.minY
    )
    self.displaySize = display.bounds.size
    self.fraction = Geometry.fraction(of: frame, in: display.bounds)
  }

  /// The frame to aim for when replaying this snapshot onto `display`.
  ///
  /// Same display size means the original pixel offsets are exactly right and are
  /// used verbatim. A different size means the resolution changed underneath us,
  /// and proportional placement is the only honest answer.
  public func targetFrame(on display: DisplayInfo) -> CGRect {
    let candidate: CGRect
    if abs(displaySize.width - display.bounds.width) < 1,
       abs(displaySize.height - display.bounds.height) < 1 {
      candidate = CGRect(
        x: display.bounds.minX + offsetInDisplay.x,
        y: display.bounds.minY + offsetInDisplay.y,
        width: frame.width,
        height: frame.height
      )
    } else {
      candidate = Geometry.absolute(fraction, in: display.bounds)
    }
    return Geometry.clamp(candidate, into: display.bounds)
  }
}

/// Every window on the current Space, for one topology, at one moment.
public struct LayoutSnapshot: Codable, Equatable, Sendable {
  public var fingerprint: String
  public var topologyLabel: String
  public var capturedAt: Date
  public var windows: [WindowSnapshot]

  public init(
    fingerprint: String,
    topologyLabel: String,
    capturedAt: Date,
    windows: [WindowSnapshot]
  ) {
    self.fingerprint = fingerprint
    self.topologyLabel = topologyLabel
    self.capturedAt = capturedAt
    self.windows = windows
  }

  /// Compares the part that matters - which windows sit where - ignoring the
  /// capture timestamp, so an idle desk does not churn the store on every tick.
  public func describesSameDesk(as other: LayoutSnapshot) -> Bool {
    fingerprint == other.fingerprint && windows == other.windows
  }
}

extension LayoutSnapshot {
  /// Folds the user's own changes into the remembered layout, leaving every other
  /// window exactly as it was.
  ///
  /// A layout is written window by window rather than replaced wholesale, because
  /// wholesale is what loses layouts: one bad measurement of the whole desk
  /// discards the good placement of every window in it, including the ones the
  /// measurement had nothing to say about. Merging means a window's remembered
  /// position can only be changed by evidence about *that window*.
  public func merging(
    _ verdict: WindowLedger.Verdict,
    topologyLabel: String? = nil,
    capturedAt: Date = Date()
  ) -> LayoutSnapshot {
    var kept = windows
    for gone in verdict.closed {
      guard let index = LayoutSnapshot.bestMatch(for: gone, in: kept) else { continue }
      kept.remove(at: index)
    }
    for window in verdict.adopted + verdict.authored {
      if let index = LayoutSnapshot.bestMatch(for: window, in: kept)
        ?? LayoutSnapshot.supersededEntry(for: window, in: kept) {
        kept[index] = window
      } else {
        kept.append(window)
      }
    }
    // Same ordering the scanner produces, so an unchanged desk still compares
    // equal to what is on file and does not churn the store.
    kept.sort { ($0.bundleID, $0.ordinal, $0.title) < ($1.bundleID, $1.ordinal, $1.title) }
    return LayoutSnapshot(
      fingerprint: fingerprint,
      topologyLabel: topologyLabel ?? self.topologyLabel,
      capturedAt: capturedAt,
      windows: kept
    )
  }

  /// The windows among `candidates` this layout has never heard of.
  ///
  /// Worth adopting at wherever they happen to be, because absence from a layout
  /// is ignorance rather than a preference: there is no remembered position to
  /// overwrite, so writing one down cannot lose anything. It is the same
  /// reasoning that lets a brand-new desk take the screen at face value, applied
  /// one window at a time.
  ///
  /// Without it a window could only ever enter a layout by being dragged, which
  /// left every window the user had simply never rearranged - most of them, on
  /// every Space they had not fiddled with - permanently unremembered and so
  /// permanently unrestorable.
  public func unknownWindows(among candidates: [WindowSnapshot]) -> [WindowSnapshot] {
    candidates.filter {
      LayoutSnapshot.bestMatch(for: $0, in: windows) == nil
        && LayoutSnapshot.supersededEntry(for: $0, in: windows) == nil
    }
  }

  /// The remembered window `window` describes, if any.
  ///
  /// Reuses the restore path's own scoring rather than matching on the window
  /// number, because the layout on file may have been written days and several
  /// window numbers ago.
  static func bestMatch(for window: WindowSnapshot, in candidates: [WindowSnapshot]) -> Int? {
    let identity = WindowIdentity(
      bundleID: window.bundleID,
      title: window.title,
      ordinal: window.ordinal,
      windowID: window.windowID,
      frame: window.frame
    )
    var best: (index: Int, score: Int)?
    for (index, candidate) in candidates.enumerated() {
      guard let score = WindowMatcher.score(live: identity, snapshot: candidate),
            score >= WindowMatcher.minimumScore else { continue }
      if best == nil || score > best!.score { best = (index, score) }
    }
    return best?.index
  }

  /// The remembered window this one has replaced, when the two cannot be matched
  /// on evidence because their window numbers disagree.
  ///
  /// `WindowMatcher` treats two different window numbers as proof of two
  /// different windows, which is right during a session and wrong across one:
  /// quit an app and reopen it and every number is reissued. Left alone, the
  /// layout would accumulate a second entry for the same window each time - the
  /// old one unmatchable forever, and counted as missing on every restore.
  ///
  /// So this asks for agreement on everything except the number: same app, same
  /// title, same position among its siblings. Strict equality on all three,
  /// because guessing here would put one window in another window's slot.
  static func supersededEntry(
    for window: WindowSnapshot,
    in candidates: [WindowSnapshot]
  ) -> Int? {
    guard window.windowID != nil, !window.title.isEmpty else { return nil }
    return candidates.firstIndex {
      $0.bundleID == window.bundleID
        && $0.title == window.title
        && $0.ordinal == window.ordinal
        && $0.windowID != window.windowID
    }
  }
}
