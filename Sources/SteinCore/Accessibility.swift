import ApplicationServices
import CoreGraphics
import Foundation

/// Thin, typed wrapper over the Accessibility API.
///
/// Every call here can block on an unresponsive app, so every element Stein
/// touches gets a messaging timeout first. Without it one hung app freezes the
/// whole scan, and the user sees a beachball caused by their window manager.
public enum AX {
  public static let messagingTimeout: Float = 0.4

  public static var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  /// Asks macOS to show the "grant Accessibility access" prompt.
  @discardableResult
  public static func requestTrust() -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
    return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  public static func application(pid: pid_t) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, messagingTimeout)
    return element
  }

  public static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
      return nil
    }
    return raw as? T
  }

  public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    value(element, attribute) as String?
  }

  public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    value(element, attribute) as Bool?
  }

  public static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let wrapped: AXValue = axValue(element, attribute) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(wrapped, .cgPoint, &point) else { return nil }
    return point
  }

  public static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let wrapped: AXValue = axValue(element, attribute) else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(wrapped, .cgSize, &size) else { return nil }
    return size
  }

  static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    return (raw as! AXValue)
  }

  @discardableResult
  public static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
    var point = point
    guard let wrapped = AXValueCreate(.cgPoint, &point) else { return false }
    return AXUIElementSetAttributeValue(
      element, kAXPositionAttribute as CFString, wrapped
    ) == .success
  }

  @discardableResult
  public static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
    var size = size
    guard let wrapped = AXValueCreate(.cgSize, &size) else { return false }
    return AXUIElementSetAttributeValue(
      element, kAXSizeAttribute as CFString, wrapped
    ) == .success
  }

  public static func frame(_ element: AXUIElement) -> CGRect? {
    guard let origin = point(element, kAXPositionAttribute),
          let size = size(element, kAXSizeAttribute) else { return nil }
    return CGRect(origin: origin, size: size)
  }

  public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(
      element, attribute as CFString, &settable
    ) == .success else { return false }
    return settable.boolValue
  }

  /// The window's CGWindowID.
  ///
  /// macOS exposes no public way to get this from an accessibility element, but
  /// it is the only stable window identity the system has, and matching windows
  /// without it is guesswork. Resolved through dlsym so a future macOS that drops
  /// the symbol degrades to title matching instead of failing to launch.
  public static var windowIDLookupAvailable: Bool {
    getWindowFunction != nil
  }

  public static func windowID(_ element: AXUIElement) -> CGWindowID? {
    guard let function = getWindowFunction else { return nil }
    var id: CGWindowID = 0
    guard function(element, &id) == .success, id != 0 else { return nil }
    return id
  }

  private typealias GetWindowFunction =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  private static let getWindowFunction: GetWindowFunction? = {
    guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: GetWindowFunction.self)
  }()
}
