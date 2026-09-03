import Carbon.HIToolbox
import Foundation
import SteinCore

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// Carbon because it is still the only way to get a system-wide hotkey without
/// asking for input monitoring, which is a much heavier permission than a window
/// manager should need on top of Accessibility.
final class HotkeyCenter {
  static let shared = HotkeyCenter()

  private var handlers: [UInt32: () -> Void] = [:]
  private var registrations: [UInt32: EventHotKeyRef] = [:]
  private var nextID: UInt32 = 1
  private var eventHandler: EventHandlerRef?

  private init() {}

  @discardableResult
  func register(_ spec: HotkeySpec, handler: @escaping () -> Void) -> Bool {
    installEventHandlerIfNeeded()

    let id = nextID
    nextID += 1
    var reference: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x53544e4b), id: id) // 'STNK'
    let status = RegisterEventHotKey(
      spec.keyCode,
      spec.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &reference
    )
    guard status == noErr, let reference else { return false }
    registrations[id] = reference
    handlers[id] = handler
    return true
  }

  func unregisterAll() {
    for reference in registrations.values {
      UnregisterEventHotKey(reference)
    }
    registrations.removeAll()
    handlers.removeAll()
  }

  private func installEventHandlerIfNeeded() {
    guard eventHandler == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let context = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &id
        )
        guard status == noErr else { return status }
        let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
        center.fire(id: id.id)
        return noErr
      },
      1,
      &spec,
      context,
      &eventHandler
    )
  }

  private func fire(id: UInt32) {
    guard let handler = handlers[id] else { return }
    DispatchQueue.main.async(execute: handler)
  }
}

extension HotkeySpec {
  static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

  /// ⌃⌥⌘ plus one key - a corner of the keyboard nothing else tends to claim.
  static func steinChord(keyCode: Int, label: String) -> HotkeySpec {
    HotkeySpec(
      keyCode: UInt32(keyCode),
      modifiers: controlOptionCommand,
      display: "⌃⌥⌘\(label)"
    )
  }

  static var restoreNow: HotkeySpec { steinChord(keyCode: kVK_ANSI_R, label: "R") }
  static var snapshotNow: HotkeySpec { steinChord(keyCode: kVK_ANSI_S, label: "S") }
  static var undoRestore: HotkeySpec { steinChord(keyCode: kVK_ANSI_Z, label: "Z") }

}
