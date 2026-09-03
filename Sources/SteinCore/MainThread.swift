import Foundation

public enum MainThread {
  /// Runs `work` on the main thread, whichever thread the caller is on.
  ///
  /// `DispatchQueue.main.sync` deadlocks when it is already the main thread, and
  /// AppKit lookups (screens, wallpaper) are main-thread-only, so both cases have
  /// to be handled in one place.
  public static func sync<T>(_ work: () -> T) -> T {
    if Thread.isMainThread { return work() }
    return DispatchQueue.main.sync(execute: work)
  }
}
