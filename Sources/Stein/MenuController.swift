import AppKit
import SteinCore

/// The status-bar menu. Stein has no main window: everything it does is either
/// automatic or one item away.
final class MenuController: NSObject, NSMenuDelegate {
  private let statusItem: NSStatusItem
  private let coordinator: Coordinator
  private let store: Store
  private var status = Status()

  init(coordinator: Coordinator, store: Store) {
    self.coordinator = coordinator
    self.store = store
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()

    if let button = statusItem.button {
      button.image = NSImage(
        systemSymbolName: "rectangle.3.group",
        accessibilityDescription: "Stein"
      )
      button.image?.isTemplate = true
      button.toolTip = "Stein"
    }
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
  }

  func update(_ status: Status) {
    self.status = status
    statusItem.button?.appearsDisabled = status.paused
    if statusItem.menu?.numberOfItems ?? 0 > 0 {
      rebuild()
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    coordinator.refresh()
    rebuild()
  }

  private func rebuild() {
    guard let menu = statusItem.menu else { return }
    menu.removeAllItems()

    if !status.trusted {
      addPermissionSection(to: menu)
      menu.addItem(.separator())
    }

    add(menu, title: status.topologyLabel.isEmpty ? "No displays" : status.topologyLabel)
      .isEnabled = false
    add(menu, title: "   \(stateLine)").isEnabled = false
    if let last = status.receipts.lastReport {
      // The one line of accountability worth keeping at the top level: an app
      // that moves your windows unasked should say what it just did. The lifetime
      // counters that used to live in a submenu here are in Copy Diagnostics,
      // where anyone actually chasing a problem will look.
      let ago = Self.formatter.localizedString(for: last.at, relativeTo: Date())
      add(menu, title: "   Last: \(last.summary) · \(ago)").isEnabled = false
    }

    menu.addItem(.separator())

    let restore = add(
      menu,
      title: "Put Windows Back",
      action: #selector(restoreNow),
      key: "r"
    )
    restore.isEnabled = status.trusted && status.hasLayoutForCurrentDesk
    add(menu, title: "Remember This Layout", action: #selector(snapshotNow), key: "s")
      .isEnabled = status.trusted
    add(menu, title: "Undo Last Restore", action: #selector(undoLastRestore), key: "z")
      .isEnabled = status.canUndo

    menu.addItem(.separator())
    let pause = add(menu, title: "Pause Learning", action: #selector(togglePause))
    pause.state = status.paused ? .on : .off

    let login = add(menu, title: "Open at Login", action: #selector(toggleLoginItem))
    login.state = LoginItem.isEnabled ? .on : .off

    let advanced = NSMenu()
    add(advanced, title: "Copy Diagnostics", action: #selector(copyDiagnostics))
    add(advanced, title: "Reveal Data Folder", action: #selector(revealDataFolder))
    add(
      advanced,
      title: "Forget All Remembered Layouts…",
      action: #selector(forgetLayouts)
    )
    let advancedItem = add(menu, title: "Advanced")
    advancedItem.submenu = advanced

    menu.addItem(.separator())
    add(menu, title: "Quit Stein", action: #selector(quit), key: "q")
  }

  private var stateLine: String {
    if !status.trusted { return "Waiting for Accessibility access" }
    if status.paused { return "Paused" }
    if status.settling { return "Displays changing…" }
    if status.hasLayoutForCurrentDesk { return "Learning · layout remembered" }
    return "Learning · nothing remembered yet"
  }

  private func addPermissionSection(to menu: NSMenu) {
    add(menu, title: "Stein needs Accessibility access").isEnabled = false
    add(
      menu,
      title: "Grant Access in System Settings…",
      action: #selector(openAccessibilitySettings)
    )
  }

  private static let formatter = RelativeDateTimeFormatter()

  @discardableResult
  private func add(
    _ menu: NSMenu,
    title: String,
    action: Selector? = nil,
    key: String = ""
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    if !key.isEmpty {
      item.keyEquivalentModifierMask = [.control, .option, .command]
    }
    item.target = action == nil ? nil : self
    menu.addItem(item)
    return item
  }

  // MARK: - Actions

  @objc private func restoreNow() {
    coordinator.restoreNow()
  }

  @objc private func snapshotNow() {
    coordinator.snapshotNow()
  }

  @objc private func undoLastRestore() {
    coordinator.undoLastRestore()
  }


  @objc private func togglePause() {
    coordinator.setPaused(!status.paused)
  }

  @objc private func forgetLayouts() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Forget every remembered layout?"
    alert.informativeText = """
      Stein will start learning each desk again from scratch the next time you \
      use it.
      """
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Forget")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    coordinator.forgetAllLayouts()
  }

  /// The same report as `Stein --check`, produced by the process that can
  /// actually see the windows. `--check` run from a terminal is attributed to the
  /// terminal for Accessibility purposes and is usually blind, which is no use in
  /// a bug report.
  @objc private func copyDiagnostics() {
    let report = Diagnostics.report(store: store)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(report, forType: .string)
    let lines = report.split(separator: "\n").count
    Toast.shared.show(title: "Diagnostics copied", detail: "\(lines) lines on the clipboard")
  }

  @objc private func revealDataFolder() {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.directory.path)
  }

  /// Opens the Accessibility pane, and nothing else.
  ///
  /// No `AX.requestTrust()` here: by the time this item is reachable Stein is
  /// already listed, and asking again would put the system's own "open System
  /// Settings" prompt on top of the System Settings window this just opened.
  @objc private func openAccessibilitySettings() {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    if let url { NSWorkspace.shared.open(url) }
  }

  @objc private func toggleLoginItem() {
    let target = !LoginItem.isEnabled
    if let message = LoginItem.setEnabled(target) {
      Toast.shared.show(title: "Could not change login item", detail: message)
    }
    coordinator.refresh()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
