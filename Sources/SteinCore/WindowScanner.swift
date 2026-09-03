import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A window that exists right now, with the handle needed to move it.
public struct LiveWindow {
  public var element: AXUIElement
  public var identity: WindowIdentity
  public var pid: pid_t
  /// False for a window sitting on one of the user's other Spaces.
  ///
  /// Such a window is *known* but not *measurable*: moving it would rearrange a
  /// desk nobody is looking at, on the strength of a frame that cannot be
  /// verified. So the flag is reported rather than the window discarded, because
  /// "must not move this now" and "this no longer exists" are different facts and
  /// conflating them made a Space switch look like the user closing everything.
  ///
  /// How many arrive false is app-dependent and not to be relied on.
  /// `kAXWindowsAttribute` reports some windows on other Spaces and not others -
  /// measured here, 8 placeable windows on this Space and 1 elsewhere, while the
  /// window server knew of 168 in total. So this flag cannot answer "does it
  /// exist"; `allWindowIDs()` does that.
  public var isOnCurrentSpace: Bool

  public init(
    element: AXUIElement,
    identity: WindowIdentity,
    pid: pid_t,
    isOnCurrentSpace: Bool = true
  ) {
    self.element = element
    self.identity = identity
    self.pid = pid
    self.isOnCurrentSpace = isOnCurrentSpace
  }
}

public enum WindowScanner {
  /// Windows Stein considers its business: standard, not minimized, not
  /// full-screen, belonging to an ordinary app - on any Space.
  ///
  /// The exclusions are deliberate rather than incidental. A minimized window has
  /// no meaningful frame and a full-screen window is owned by the system, so
  /// moving either is worse than leaving it alone.
  ///
  /// Another Space is not such a case, and treating it as one was a mistake.
  /// Those windows are still listed here, flagged `isOnCurrentSpace = false`, so
  /// that "I must not move this now" stays distinct from "this no longer exists".
  /// Dropping them outright meant a layout only ever held the Space that happened
  /// to be visible, and switching Space rewrote it.
  public static func scan() -> [LiveWindow] {
    let onCurrentSpace = windowIDsOnCurrentSpace()
    let ownPID = ProcessInfo.processInfo.processIdentifier
    var result: [LiveWindow] = []

    for app in NSWorkspace.shared.runningApplications {
      guard app.activationPolicy == .regular,
            !app.isHidden,
            app.processIdentifier != ownPID,
            app.processIdentifier > 0,
            let bundleID = app.bundleIdentifier else { continue }

      let appElement = AX.application(pid: app.processIdentifier)
      guard let windows: [AXUIElement] = AX.value(appElement, kAXWindowsAttribute as String) else {
        continue
      }

      for (ordinal, window) in windows.enumerated() {
        AXUIElementSetMessagingTimeout(window, AX.messagingTimeout)
        guard let identity = identity(of: window, bundleID: bundleID, ordinal: ordinal) else {
          continue
        }
        // An unavailable window number leaves no way to check the Space, and
        // guessing "elsewhere" would silently freeze the window out of every
        // layout. Assume it is here; title and ordinal matching still apply.
        let here = identity.windowID.map { onCurrentSpace.isEmpty || onCurrentSpace.contains($0) }
          ?? true
        result.append(
          LiveWindow(
            element: window,
            identity: identity,
            pid: app.processIdentifier,
            isOnCurrentSpace: here
          )
        )
      }
    }
    return result
  }

  static func identity(
    of window: AXUIElement,
    bundleID: String,
    ordinal: Int
  ) -> WindowIdentity? {
    guard AX.string(window, kAXRoleAttribute as String) == kAXWindowRole as String else {
      return nil
    }
    let subrole = AX.string(window, kAXSubroleAttribute as String)
    guard subrole == nil || subrole == kAXStandardWindowSubrole as String else { return nil }
    if AX.bool(window, kAXMinimizedAttribute as String) == true { return nil }
    if AX.bool(window, "AXFullScreen") == true { return nil }

    guard let frame = AX.frame(window),
          frame.width >= 80,
          frame.height >= 60 else { return nil }

    return WindowIdentity(
      bundleID: bundleID,
      title: AX.string(window, kAXTitleAttribute as String) ?? "",
      ordinal: ordinal,
      windowID: AX.windowID(window),
      frame: frame
    )
  }

  /// Every window number that exists right now: every Space, plus minimized
  /// windows.
  ///
  /// This is the one dependable public answer to "does that window still exist?".
  /// The Accessibility API cannot be asked: it reports an app's windows on other
  /// Spaces sometimes and not others, so its silence proves nothing. Measured
  /// here, AX offered 9 windows - 8 on this Space and 1 elsewhere - while this
  /// call listed 168. Without it, a window on another Space is indistinguishable
  /// from a window that was closed, and treating the first as the second is how a
  /// layout loses every Space the user is not looking at.
  public static func allWindowIDs() -> Set<CGWindowID> {
    ids(matching: [.optionAll, .excludeDesktopElements])
  }

  /// Window numbers currently on screen, which on macOS means "on the Space the
  /// user is looking at". Layer 0 keeps out panels, menus and the desktop itself.
  public static func windowIDsOnCurrentSpace() -> Set<CGWindowID> {
    ids(matching: [.optionOnScreenOnly, .excludeDesktopElements])
  }

  static func ids(matching options: CGWindowListOption) -> Set<CGWindowID> {
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    var ids = Set<CGWindowID>()
    for entry in list {
      guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
            let number = entry[kCGWindowNumber as String] as? UInt32 else { continue }
      ids.insert(number)
    }
    return ids
  }

  /// A cheap fingerprint of every window's position, without touching the
  /// Accessibility API.
  ///
  /// The full scan is dozens of cross-process AX round-trips, and on an idle desk
  /// every one of them is wasted: a layout only changes when a window moves,
  /// resizes, opens or closes. `CGWindowListCopyWindowInfo` reports all of that in
  /// one call, so it can act as the gate. Sorted by window number, because a
  /// window merely coming to the front is not a layout change.
  public static func deskDigest() -> UInt64 {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return 0 }

    var entries: [(number: Int, pid: Int, frame: CGRect)] = []
    for entry in list {
      guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
            let number = entry[kCGWindowNumber as String] as? Int,
            let pid = entry[kCGWindowOwnerPID as String] as? Int,
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
      var frame = CGRect.zero
      guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame) else { continue }
      entries.append((number, pid, frame))
    }
    entries.sort { $0.number < $1.number }

    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ value: Int) {
      var remaining = UInt64(bitPattern: Int64(value))
      for _ in 0..<8 {
        hash = (hash ^ (remaining & 0xff)) &* 0x0000_0100_0000_01b3
        remaining >>= 8
      }
    }
    for entry in entries {
      mix(entry.number)
      mix(entry.pid)
      mix(Int(entry.frame.minX))
      mix(Int(entry.frame.minY))
      mix(Int(entry.frame.width))
      mix(Int(entry.frame.height))
    }
    return hash
  }

  /// What one look at the desk established: the windows that could be measured,
  /// and the window numbers that exist whether they could be measured or not.
  public struct Measurement {
    public var observable: [WindowSnapshot]
    /// Every window number alive anywhere. The answer to "is it gone, or just out
    /// of sight?", which nothing in `observable` can settle.
    public var existingIDs: Set<CGWindowID>

    public init(observable: [WindowSnapshot], existingIDs: Set<CGWindowID>) {
      self.observable = observable
      self.existingIDs = existingIDs
    }
  }

  public static func measure(topology: Topology, windows: [LiveWindow]? = nil) -> Measurement {
    let live = windows ?? scan()
    return Measurement(
      observable: snapshot(
        topology: topology,
        windows: live.filter(\.isOnCurrentSpace)
      ).windows,
      existingIDs: allWindowIDs()
    )
  }

  /// Turns the live desk into something worth remembering.
  public static func snapshot(topology: Topology, windows: [LiveWindow]? = nil) -> LayoutSnapshot {
    let live = windows ?? scan()
    var entries: [WindowSnapshot] = []
    for window in live {
      guard let display = Geometry.display(
        hosting: window.identity.frame,
        among: topology.displays
      ) else { continue }
      entries.append(
        WindowSnapshot(
          bundleID: window.identity.bundleID,
          appName: NSRunningApplication(processIdentifier: window.pid)?.localizedName
            ?? window.identity.bundleID,
          windowID: window.identity.windowID,
          title: window.identity.title,
          ordinal: window.identity.ordinal,
          frame: window.identity.frame,
          display: display
        )
      )
    }
    // Sorted so an unchanged desk always produces a byte-identical snapshot and
    // does not look like a change to the store.
    entries.sort {
      ($0.bundleID, $0.ordinal, $0.title) < ($1.bundleID, $1.ordinal, $1.title)
    }
    return LayoutSnapshot(
      fingerprint: topology.fingerprint,
      topologyLabel: topology.label,
      capturedAt: Date(),
      windows: entries
    )
  }
}
