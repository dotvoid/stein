import Foundation

/// A key combination, stored as the Carbon values needed to register it.
public struct HotkeySpec: Codable, Equatable, Sendable {
  public var keyCode: UInt32
  /// Carbon modifier mask (cmdKey / optionKey / controlKey / shiftKey).
  public var modifiers: UInt32
  /// Pre-rendered for menus: "⌃⌥⌘R".
  public var display: String

  public init(keyCode: UInt32, modifiers: UInt32, display: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.display = display
  }
}
