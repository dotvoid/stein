import CoreGraphics
import Foundation

/// The state of the login session, as far as it affects whether the desk in front
/// of Stein can be believed.
public enum Session {
  /// Keys of `CGSessionCopyCurrentDictionary`, spelled out rather than taken from
  /// the CoreGraphics constants: they are C macros, and not all of them reach
  /// Swift.
  private static let onConsoleKey = "kCGSSessionOnConsoleKey"
  private static let screenLockedKey = "CGSSessionScreenIsLocked"

  /// True when this session owns the screen and the screen is not locked.
  ///
  /// Measuring a locked desk is worse than not measuring it at all.
  /// `CGWindowListCopyWindowInfo` reports almost nothing while the lock screen is
  /// up, so the Space filter in `WindowScanner` throws away nearly every window
  /// and a full desk measures as one or two strays - a perfectly well-formed
  /// layout that happens to be a lie. Without this check Stein learns that lie
  /// and files it over the real thing.
  public static var isActive: Bool {
    guard let info = CGSessionCopyCurrentDictionary() as NSDictionary? else {
      // No session dictionary at all means Stein is not in a GUI session - a
      // diagnostics run from a terminal. Nothing is learned from there anyway.
      return true
    }
    let onConsole = info[onConsoleKey] as? Bool ?? true
    let locked = info[screenLockedKey] as? Bool ?? false
    return onConsole && !locked
  }
}
