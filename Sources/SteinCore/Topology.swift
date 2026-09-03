import CoreGraphics
import Foundation

/// One display, identified by something that survives a reboot and a re-plug.
public struct DisplayInfo: Codable, Equatable, Sendable {
  /// Stable identity: the display's UUID when macOS gives us one, otherwise a
  /// vendor/model/serial composite. Never the CGDirectDisplayID, which is handed
  /// out fresh on every reconnect and is therefore worthless as memory.
  public let id: String
  public let name: String
  /// Global coordinates, top-left origin - the same space the Accessibility API
  /// speaks, so no flipping is ever needed between measuring and placing.
  public let bounds: CGRect
  public let isMain: Bool

  public init(id: String, name: String, bounds: CGRect, isMain: Bool) {
    self.id = id
    self.name = name
    self.bounds = bounds
    self.isMain = isMain
  }
}

/// The whole desk: every attached display and how they are arranged.
public struct Topology: Codable, Equatable, Sendable {
  public let displays: [DisplayInfo]

  public init(displays: [DisplayInfo]) {
    self.displays = displays.sorted { $0.id < $1.id }
  }

  /// The version prefix on every fingerprint. Bumped when the identity rule
  /// changes, so layouts filed under an older rule are discarded rather than
  /// misapplied.
  public static let fingerprintVersion = "v2"

  /// The key layouts are filed under: which panels, at which sizes.
  ///
  /// Deliberately *excludes* where the displays sit relative to each other, and
  /// which one holds the menu bar. Both were in v1 and both were a mistake. Real
  /// usage showed macOS reporting two different arrangements for the same two
  /// panels within a minute of a reconnect - the external display appearing to the
  /// left, then above - which forked one desk into two and orphaned the layout
  /// that had been learned. Nothing is lost by ignoring the arrangement, because
  /// every window is recorded relative to its own display's origin, so a
  /// remembered layout replays correctly wherever that display has moved to.
  ///
  /// Sizes stay in: a display coming back in a different scaled mode is a
  /// deliberate, rare change, and one worth remembering a separate layout for.
  public var fingerprint: String {
    let parts = displays.map { display in
      "\(display.id):\(Int(display.bounds.width))x\(Int(display.bounds.height))"
    }
    return Topology.fingerprintVersion + "|" + parts.joined(separator: "|")
  }

  /// Human-readable name for the menu: "MacBook Pro + Studio Display".
  public var label: String {
    guard !displays.isEmpty else { return "No displays" }
    let ordered = displays.sorted { lhs, rhs in
      if lhs.isMain != rhs.isMain { return lhs.isMain }
      return lhs.bounds.minX < rhs.bounds.minX
    }
    return ordered.map(\.name).joined(separator: " + ")
  }

  public func display(id: String) -> DisplayInfo? {
    displays.first { $0.id == id }
  }

  public var main: DisplayInfo? {
    displays.first { $0.isMain } ?? displays.first
  }
}
