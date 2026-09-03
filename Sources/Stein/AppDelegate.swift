import AppKit
import SteinCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let store = Store()
  private var coordinator: Coordinator!
  private var menu: MenuController!
  private var trustPollTimer: Timer?
  private var wasTrusted = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    coordinator = Coordinator(store: store)
    menu = MenuController(coordinator: coordinator, store: store)
    coordinator.onStatus = { [weak self] status in
      self?.menu.update(status)
    }

    registerHotkeys()
    wasTrusted = AX.isTrusted
    coordinator.start()

    if wasTrusted {
      Toast.shared.show(title: "Stein is watching", detail: "Learning this desk")
    } else {
      requestAccessibility()
    }
    startTrustPolling()
  }

  func applicationWillTerminate(_ notification: Notification) {
    HotkeyCenter.shared.unregisterAll()
    trustPollTimer?.invalidate()
  }

  private func registerHotkeys() {
    HotkeyCenter.shared.register(.restoreNow) { [weak self] in
      self?.coordinator.restoreNow()
    }
    HotkeyCenter.shared.register(.snapshotNow) { [weak self] in
      self?.coordinator.snapshotNow()
    }
    HotkeyCenter.shared.register(.undoRestore) { [weak self] in
      self?.coordinator.undoLastRestore()
    }
  }

  private func requestAccessibility() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Stein needs Accessibility access"
    alert.informativeText = """
      Moving another app's windows is a privileged operation on macOS, so Stein \
      cannot do anything at all until you allow it in System Settings › Privacy & \
      Security › Accessibility.

      Nothing leaves your Mac. Layouts are plain JSON in \
      ~/Library/Application Support/Stein.
      """
    // "Continue" rather than "Open System Settings", because macOS asks next and
    // its own prompt is the thing that opens Settings. Promising to open Settings
    // and then producing another dialog that asks to open Settings is how one
    // permission request came to look like three.
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Later")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    // This is the only thing that happens here. It registers Stein in the
    // Accessibility list and presents the system prompt, whose own button opens
    // System Settings - so opening Settings from here as well produced a second,
    // redundant request on top of a window that was already open.
    AX.requestTrust()
  }

  /// macOS sends no notification when Accessibility access is granted, so the only
  /// way to notice is to keep asking.
  private func startTrustPolling() {
    trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      guard let self else { return }
      let trusted = AX.isTrusted
      guard trusted != wasTrusted else { return }
      wasTrusted = trusted
      coordinator.refresh()
      if trusted {
        Toast.shared.show(title: "Stein is watching", detail: "Learning this desk")
        coordinator.snapshotNow()
      } else {
        // Access was revoked, or - far more often during development - a rebuild
        // changed the ad-hoc signature and macOS quietly stopped honouring the
        // existing grant. Either way Stein can no longer do anything, so it says
        // so rather than sitting there looking busy.
        Toast.shared.show(
          title: "Accessibility access lost",
          detail: "Stein cannot move windows until it is granted again"
        )
        AX.requestTrust()
      }
    }
  }
}
