import ApplicationServices
import CoreGraphics
import Foundation

public enum WindowPlacer {
  public enum Outcome: Equatable {
    /// Already where it belongs.
    case unchanged
    /// Moved and verified on the first attempt.
    case placed
    /// Needed the second attempt with the writes reordered.
    case retried
    /// Would not stay put.
    case failed
  }

  /// How long to let a window settle before believing what it reports.
  ///
  /// Chromium and Electron windows re-measure themselves right after a move, so
  /// reading the frame back immediately returns the value from before the move.
  static let settleMicroseconds: UInt32 = 15_000

  /// Moves one window and then checks that it actually went there.
  ///
  /// The verify pass is the whole trick. Setting position and size through the
  /// Accessibility API is a request, not a command: apps clamp sizes, snap to
  /// their own grids, or bounce a window back after re-measuring. Writing the
  /// values and walking away produces a layout that is right for most windows and
  /// quietly wrong for the interesting ones. When the first attempt does not hold,
  /// the second reverses the order - size before position - which is what the
  /// re-measuring apps need, because they recompute position from the new size.
  public static func place(_ window: LiveWindow, at target: CGRect) -> Outcome {
    let element = window.element
    guard let before = AX.frame(element) else { return .failed }
    if Geometry.matches(before, target) { return .unchanged }

    let resizable = AX.isSettable(element, kAXSizeAttribute as String)

    AX.setPosition(element, target.origin)
    if resizable { AX.setSize(element, target.size) }
    usleep(settleMicroseconds)
    if landed(element, target: target, resizable: resizable, tolerance: 2) { return .placed }

    if resizable { AX.setSize(element, target.size) }
    AX.setPosition(element, target.origin)
    usleep(settleMicroseconds)
    if landed(element, target: target, resizable: resizable, tolerance: 6) { return .retried }

    return .failed
  }

  static func landed(
    _ element: AXUIElement,
    target: CGRect,
    resizable: Bool,
    tolerance: CGFloat
  ) -> Bool {
    guard let now = AX.frame(element) else { return false }
    let positionOK = abs(now.minX - target.minX) <= tolerance
      && abs(now.minY - target.minY) <= tolerance
    guard positionOK else { return false }
    guard resizable else { return true }
    // A window that refuses to shrink past its own minimum is obeying, not
    // failing; the position is what the user notices.
    let tooSmall = now.width < target.width || now.height < target.height
    let sizeOK = abs(now.width - target.width) <= tolerance
      && abs(now.height - target.height) <= tolerance
    return sizeOK || tooSmall
  }
}
