import CoreGraphics
import Foundation
import Testing
@testable import SteinCore

@Suite("Window snapshots")
struct WindowSnapshotTests {
  private let ultrawide = DisplayInfo(
    id: "wide",
    name: "Ultrawide",
    bounds: CGRect(x: 1512, y: 0, width: 3440, height: 1440),
    isMain: true
  )
  private let laptop = DisplayInfo(
    id: "laptop",
    name: "Built-in Display",
    bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
    isMain: false
  )

  private func snapshot(frame: CGRect, on display: DisplayInfo) -> WindowSnapshot {
    WindowSnapshot(
      bundleID: "com.example.app",
      appName: "App",
      windowID: 42,
      title: "Window",
      ordinal: 0,
      frame: frame,
      display: display
    )
  }

  @Test("Capture records the offset within the display, not just the global frame")
  func captureRecordsOffset() {
    let entry = snapshot(
      frame: CGRect(x: 1512 + 1720, y: 0, width: 1720, height: 1440),
      on: ultrawide
    )
    #expect(entry.offsetInDisplay == CGPoint(x: 1720, y: 0))
    #expect(entry.displaySize == CGSize(width: 3440, height: 1440))
    #expect(abs(entry.fraction.x - 0.5) < 0.0001)
  }

  @Test("Replaying onto the same display reproduces the frame exactly")
  func sameDisplayIsExact() {
    let frame = CGRect(x: 1512 + 200, y: 120, width: 1400, height: 900)
    #expect(snapshot(frame: frame, on: ultrawide).targetFrame(on: ultrawide) == frame)
  }

  @Test("Replaying onto a moved display follows the display, keeping pixel offsets")
  func movedDisplayKeepsOffsets() {
    let frame = CGRect(x: 1512 + 200, y: 120, width: 1400, height: 900)
    let entry = snapshot(frame: frame, on: ultrawide)
    // Same panel, now to the left of the laptop instead of the right.
    let moved = DisplayInfo(
      id: "wide",
      name: "Ultrawide",
      bounds: CGRect(x: -3440, y: 0, width: 3440, height: 1440),
      isMain: false
    )
    #expect(
      entry.targetFrame(on: moved)
        == CGRect(x: -3440 + 200, y: 120, width: 1400, height: 900)
    )
  }

  @Test("A display that came back at a lower resolution gets proportional placement")
  func resolutionChangeIsProportional() {
    // Right half of the ultrawide.
    let entry = snapshot(
      frame: CGRect(x: 1512 + 1720, y: 0, width: 1720, height: 1440),
      on: ultrawide
    )
    let scaled = DisplayInfo(
      id: "wide",
      name: "Ultrawide",
      bounds: CGRect(x: 0, y: 0, width: 2560, height: 1080),
      isMain: true
    )
    #expect(
      entry.targetFrame(on: scaled) == CGRect(x: 1280, y: 0, width: 1280, height: 1080)
    )
  }

  @Test("A window from a big display lands inside a small one")
  func fallbackDisplayIsClamped() {
    let entry = snapshot(
      frame: CGRect(x: 1512 + 1720, y: 0, width: 1720, height: 1440),
      on: ultrawide
    )
    let target = entry.targetFrame(on: laptop)
    #expect(laptop.bounds.contains(target))
  }

  @Test("An idle desk produces snapshots that compare equal despite new timestamps")
  func sameDeskIgnoresTimestamp() {
    let windows = [snapshot(frame: CGRect(x: 1512, y: 0, width: 800, height: 600), on: ultrawide)]
    let first = LayoutSnapshot(
      fingerprint: "fp", topologyLabel: "desk", capturedAt: Date(timeIntervalSince1970: 0),
      windows: windows
    )
    let second = LayoutSnapshot(
      fingerprint: "fp", topologyLabel: "desk", capturedAt: Date(timeIntervalSince1970: 9999),
      windows: windows
    )
    #expect(first.describesSameDesk(as: second))
    #expect(first != second)
  }

  @Test("A snapshot survives a round trip through JSON")
  func codableRoundTrip() throws {
    let entry = snapshot(frame: CGRect(x: 1600, y: 40, width: 900, height: 700), on: ultrawide)
    let data = try JSONEncoder().encode(entry)
    #expect(try JSONDecoder().decode(WindowSnapshot.self, from: data) == entry)
  }

}
