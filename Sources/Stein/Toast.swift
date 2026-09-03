import AppKit
import SteinCore

/// The receipt. A small panel in the top-right corner saying what just happened.
///
/// Stein moves the user's windows without being asked, which is only acceptable if
/// it always says what it did. This is deliberately not a system notification:
/// those need permission, land in a centre nobody reads, and can be silenced -
/// none of which suits a message whose entire job is accountability.
final class Toast {
  static let shared = Toast()

  private var panel: NSPanel?
  private var dismissWorkItem: DispatchWorkItem?

  private let width: CGFloat = 288
  /// Inset from the screen edge.
  ///
  /// Has to clear the panel's own drop shadow, which is drawn *outside* the
  /// window frame and gets clipped by the edge of the display. At 14 points the
  /// shadow was cut off, which reads as the panel itself hanging off the screen.
  private let margin: CGFloat = 24
  private let visibleDuration: TimeInterval = 3.4

  private init() {
    // A toast shown during a display change is positioned from an arrangement
    // macOS is still rearranging, and it used to keep those coordinates for its
    // whole life - which is exactly when Stein has most to say.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, let panel, panel.isVisible else { return }
      position(panel)
    }
  }

  func show(title: String, detail: String) {
    dismissWorkItem?.cancel()
    let panel = existingOrNewPanel()
        guard let content = panel.contentView as? ToastView else { return }
    content.update(title: title, detail: detail)
    position(panel)

    if panel.alphaValue < 1 {
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
      }
    } else {
      panel.orderFrontRegardless()
    }

    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    dismissWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: work)
  }

  func report(_ report: RestoreReport) {
    guard !report.wasIneffective else {
      // Saying "0 windows" under the desk's own name reads as success, and this
      // is not one: the remembered layout matched nothing on screen. Nothing has
      // been lost - the layout stays on file, untouched - but the user is the
      // only one who can say why their windows are not where they left them.
      show(title: "Nothing to put back", detail: report.summary)
      return
    }
    show(title: report.title, detail: report.summary)
  }

  private func dismiss() {
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.24
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: {
      panel.orderOut(nil)
    }
  }

  private func existingOrNewPanel() -> NSPanel {
    if let panel { return panel }
    let view = ToastView(frame: NSRect(x: 0, y: 0, width: width, height: 64))
    let panel = NSPanel(
      contentRect: view.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = view
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.alphaValue = 0
    self.panel = panel
    return panel
  }

  /// Top-right of the screen the user is working on.
  ///
  /// `NSScreen.main` means "the screen with keyboard focus", which is the right
  /// answer for a message that has to be noticed, but it is optional and it is
  /// read while the display arrangement may still be in flux. So the result is
  /// clamped into the chosen screen - the same guarantee `Geometry.clamp` gives
  /// every window Stein places, applied to Stein's own panel, so that whatever
  /// the arrangement claims the toast cannot end up off the edge.
  private func position(_ panel: NSPanel) {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let height = (panel.contentView as? ToastView)?.fittingHeight ?? 64
    let bounds = screen.visibleFrame.insetBy(dx: margin, dy: margin)
    let wanted = CGRect(
      x: bounds.maxX - width,
      y: bounds.maxY - height,
      width: width,
      height: height
    )
    panel.setFrame(Geometry.clamp(wanted, into: bounds), display: false)
  }
}

private final class ToastView: NSView {
  private let background = NSVisualEffectView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let mark = NSImageView()

  var fittingHeight: CGFloat { 64 }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    build()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    build()
  }

  private func build() {
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 14
    background.layer?.cornerCurve = .continuous
    // A hairline keeps the panel from dissolving into a light wallpaper.
    background.layer?.borderWidth = 1
    background.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    background.translatesAutoresizingMaskIntoConstraints = false
    addSubview(background)

    mark.image = NSImage(
      systemSymbolName: "rectangle.3.group",
      accessibilityDescription: "Stein"
    )
    mark.contentTintColor = .secondaryLabelColor
    mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
    mark.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .labelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    // Monospaced digits so a count ticking from 9 to 10 does not shift the line.
    detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byTruncatingTail
    detailLabel.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [titleLabel, detailLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false

    background.addSubview(mark)
    background.addSubview(stack)

    NSLayoutConstraint.activate([
      background.leadingAnchor.constraint(equalTo: leadingAnchor),
      background.trailingAnchor.constraint(equalTo: trailingAnchor),
      background.topAnchor.constraint(equalTo: topAnchor),
      background.bottomAnchor.constraint(equalTo: bottomAnchor),
      mark.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
      mark.centerYAnchor.constraint(equalTo: background.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 11),
      stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
      stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
    ])
  }

  func update(title: String, detail: String) {
    titleLabel.stringValue = title
    detailLabel.stringValue = detail
  }
}
