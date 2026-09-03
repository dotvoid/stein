import CoreGraphics
import Foundation

/// A frame expressed as fractions (0...1) of a display's bounds.
///
/// Fractions are how Stein survives a resolution change: a window that filled the
/// right half of a 3440x1440 ultrawide should fill the right half again when that
/// same display comes back running a scaled mode.
public struct FractionalFrame: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public enum Geometry {
  /// The smallest window Stein will ever ask for. Below this a window is unusable
  /// and almost certainly the result of bad arithmetic rather than intent.
  public static let minimumWindowSize = CGSize(width: 120, height: 90)

  public static func fraction(of rect: CGRect, in bounds: CGRect) -> FractionalFrame {
    guard bounds.width > 0, bounds.height > 0 else {
      return FractionalFrame(x: 0, y: 0, width: 1, height: 1)
    }
    return FractionalFrame(
      x: (rect.minX - bounds.minX) / bounds.width,
      y: (rect.minY - bounds.minY) / bounds.height,
      width: rect.width / bounds.width,
      height: rect.height / bounds.height
    )
  }

  public static func absolute(_ fraction: FractionalFrame, in bounds: CGRect) -> CGRect {
    CGRect(
      x: bounds.minX + fraction.x * bounds.width,
      y: bounds.minY + fraction.y * bounds.height,
      width: fraction.width * bounds.width,
      height: fraction.height * bounds.height
    )
  }

  /// Pull `rect` fully inside `bounds`, shrinking it first if it cannot fit.
  ///
  /// Origin is preserved as far as possible so a window that was near the top-left
  /// of its display stays near the top-left rather than being recentred.
  public static func clamp(
    _ rect: CGRect,
    into bounds: CGRect,
    minSize: CGSize = Geometry.minimumWindowSize
  ) -> CGRect {
    let width = min(max(rect.width, min(minSize.width, bounds.width)), bounds.width)
    let height = min(max(rect.height, min(minSize.height, bounds.height)), bounds.height)
    let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
    let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
    return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
  }

  /// True when two frames agree closely enough that a move counts as landed.
  ///
  /// Chromium-based apps re-measure themselves after a move and can settle a point
  /// or two off; a hard equality check would send Stein into a pointless retry loop.
  public static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) <= tolerance
      && abs(a.minY - b.minY) <= tolerance
      && abs(a.width - b.width) <= tolerance
      && abs(a.height - b.height) <= tolerance
  }

  /// The display that holds most of `rect`, or the one it is nearest to.
  public static func display(
    hosting rect: CGRect,
    among displays: [DisplayInfo]
  ) -> DisplayInfo? {
    var best: (display: DisplayInfo, overlap: CGFloat)?
    for display in displays {
      let intersection = display.bounds.intersection(rect)
      let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
      if best == nil || overlap > best!.overlap {
        best = (display, overlap)
      }
    }
    guard let best else { return nil }
    if best.overlap > 0 { return best.display }
    // Fully off-screen (a window stranded on a display that just vanished):
    // fall back to whichever display centre is closest.
    return displays.min {
      distance(from: rect.center, to: $0.bounds.center)
        < distance(from: rect.center, to: $1.bounds.center)
    }
  }

  static func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
  }
}

extension CGRect {
  var center: CGPoint { CGPoint(x: midX, y: midY) }
}
