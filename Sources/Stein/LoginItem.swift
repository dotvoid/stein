import Foundation
import ServiceManagement

/// Start-at-login, through the modern API that needs no helper bundle.
enum LoginItem {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Returns the error message when the change could not be made.
  ///
  /// Registration fails for an app that is not in a normal location - a build
  /// directory, a mounted disk image - which is worth telling the user rather
  /// than silently leaving a checkbox in the wrong state.
  static func setEnabled(_ enabled: Bool) -> String? {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}
