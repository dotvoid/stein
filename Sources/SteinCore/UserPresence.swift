import CoreGraphics
import Foundation

/// Whether a human has touched this machine lately.
///
/// The one signal that separates a layout from an accident. Stein cannot ask why
/// a window moved, but it can ask whether anybody was here when it did, and that
/// turns out to be enough: macOS evacuates a departing display's windows with
/// nobody at the keyboard, and a person arranging their desk cannot.
///
/// Reading input *timing* needs no permission and sees no content - this is the
/// same idle clock a screen saver runs on, not an event tap.
public enum UserPresence {
  /// Input that means a person is here. Deliberately generous: this is only ever
  /// used to rule out "nobody touched anything", never to prove intent.
  private static let inputTypes: [CGEventType] = [
    .keyDown,
    .leftMouseDown,
    .leftMouseDragged,
    .rightMouseDown,
    .otherMouseDown,
    .mouseMoved,
    .scrollWheel
  ]

  /// Slack between the event source's clock and Stein's own timestamps.
  static let tolerance: TimeInterval = 0.5

  public static var secondsSinceInput: TimeInterval {
    inputTypes
      .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
      .min() ?? .greatestFiniteMagnitude
  }

  /// True when at least one human input landed since `date`.
  public static func active(
    since date: Date,
    now: Date = Date(),
    idle: TimeInterval? = nil
  ) -> Bool {
    let elapsed = now.timeIntervalSince(date)
    guard elapsed > 0 else { return false }
    return (idle ?? secondsSinceInput) <= elapsed + tolerance
  }
}
