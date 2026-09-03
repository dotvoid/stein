import AppKit

if CommandLine.arguments.contains("--check") {
  Diagnostics.run()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// No Dock icon, no menu bar of its own: Stein lives in the status bar.
application.setActivationPolicy(.accessory)
application.run()
