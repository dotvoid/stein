import CoreGraphics
import Foundation
import Testing
@testable import SteinCore

@Suite("Restore targeting")
struct RestoreEngineTests {
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

  private func snapshot(on display: DisplayInfo) -> WindowSnapshot {
    WindowSnapshot(
      bundleID: "com.example.app",
      appName: "App",
      windowID: 1,
      title: "Window",
      ordinal: 0,
      frame: CGRect(x: display.bounds.minX + 40, y: 60, width: 900, height: 700),
      display: display
    )
  }

  @Test("A window goes back to its own display when that display is still there")
  func prefersOriginalDisplay() {
    let topology = Topology(
      displays: [
        ultrawide,
        DisplayInfo(id: "laptop", name: "Built-in", bounds: laptop.bounds, isMain: false)
      ]
    )
    let target = RestoreEngine.targetDisplay(for: snapshot(on: ultrawide), in: topology)
    #expect(target?.id == "wide")
  }

  @Test("A window whose display is gone falls back to the main display")
  func fallsBackToMainDisplay() {
    // Undocked: only the built-in display is left, and it is now main.
    let alone = DisplayInfo(
      id: "laptop", name: "Built-in Display", bounds: laptop.bounds, isMain: true
    )
    let target = RestoreEngine.targetDisplay(
      for: snapshot(on: ultrawide),
      in: Topology(displays: [alone])
    )
    #expect(target?.id == "laptop")
  }

  @Test("The fallback lands the window inside the display that is left")
  func fallbackFrameFitsRemainingDisplay() {
    let alone = DisplayInfo(
      id: "laptop", name: "Built-in Display", bounds: laptop.bounds, isMain: true
    )
    let entry = WindowSnapshot(
      bundleID: "com.example.app",
      appName: "App",
      windowID: 1,
      title: "Window",
      ordinal: 0,
      // Right half of the ultrawide, entirely outside the laptop's coordinates.
      frame: CGRect(x: 1512 + 1720, y: 0, width: 1720, height: 1440),
      display: ultrawide
    )
    let target = RestoreEngine.targetDisplay(for: entry, in: Topology(displays: [alone]))
    let frame = entry.targetFrame(on: target!)
    #expect(alone.bounds.contains(frame))
    // Proportional placement: it owned the right half, so it keeps the right half.
    #expect(frame.midX > alone.bounds.midX)
  }

  @Test("With no displays attached there is nowhere to put anything")
  func noDisplaysMeansNoTarget() {
    #expect(
      RestoreEngine.targetDisplay(for: snapshot(on: ultrawide), in: Topology(displays: [])) == nil
    )
  }
}
