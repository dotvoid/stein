import AppKit
import CoreGraphics
import Foundation

public enum Displays {
  /// The desk as it exists right now.
  public static func current() -> Topology {
    Topology(displays: activeDisplayIDs().compactMap(info(for:)))
  }

  public static func activeDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
  }

  static func info(for id: CGDirectDisplayID) -> DisplayInfo? {
    // Mirrored displays share their master's pixels; treating them as separate
    // desks would double-count the same physical screen.
    guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
    return DisplayInfo(
      id: identity(of: id),
      name: name(of: id),
      bounds: CGDisplayBounds(id),
      isMain: CGDisplayIsMain(id) != 0
    )
  }

  /// A name for a display that outlives the current session.
  ///
  /// CGDirectDisplayID is recycled by the window server and changes between
  /// reconnects, so it can identify a display now but never remember one.
  static func identity(of id: CGDirectDisplayID) -> String {
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
       let string = CFUUIDCreateString(nil, uuid) as String? {
      return string
    }
    // Virtual and DisplayLink displays often have no UUID. Vendor, model and
    // serial together are still stable for a given panel on a given port.
    let vendor = CGDisplayVendorNumber(id)
    let model = CGDisplayModelNumber(id)
    let serial = CGDisplaySerialNumber(id)
    let unit = CGDisplayUnitNumber(id)
    return "vms:\(vendor)-\(model)-\(serial)-\(unit)"
  }

  static func name(of id: CGDirectDisplayID) -> String {
    let screen = NSScreen.screens.first { candidate in
      let number = candidate.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber
      return number?.uint32Value == id
    }
    if let name = screen?.localizedName, !name.isEmpty { return name }
    if CGDisplayIsBuiltin(id) != 0 { return "Built-in Display" }
    return "Display \(id)"
  }
}
