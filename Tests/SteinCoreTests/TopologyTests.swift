import CoreGraphics
import Testing
@testable import SteinCore

@Suite("Topology")
struct TopologyTests {
  private func display(
    _ id: String,
    _ bounds: CGRect,
    main: Bool = false,
    name: String? = nil
  ) -> DisplayInfo {
    DisplayInfo(id: id, name: name ?? id, bounds: bounds, isMain: main)
  }

  @Test("The fingerprint ignores the order displays were enumerated in")
  func fingerprintIsOrderIndependent() {
    let a = display("A", CGRect(x: 0, y: 0, width: 3440, height: 1440), main: true)
    let b = display("B", CGRect(x: 0, y: 1440, width: 1512, height: 982))
    #expect(Topology(displays: [a, b]).fingerprint == Topology(displays: [b, a]).fingerprint)
  }

  @Test("Docking a second display is a different desk")
  func fingerprintChangesWithDisplayCount() {
    let laptop = display("A", CGRect(x: 0, y: 0, width: 1512, height: 982), main: true)
    let docked = display("B", CGRect(x: 1512, y: 0, width: 3440, height: 1440))
    #expect(
      Topology(displays: [laptop]).fingerprint
        != Topology(displays: [laptop, docked]).fingerprint
    )
  }

  @Test("Rearranging the same displays is still the same desk")
  func arrangementDoesNotForkTheDesk() {
    // v1 keyed on origins and it fragmented memory: macOS reported the same two
    // panels as left-adjacent and then as stacked within a minute of a reconnect,
    // forking one desk in two and orphaning the layout already learned. Window
    // frames are stored relative to their own display, so the arrangement does
    // not need to be part of the desk's identity.
    let laptop = display("A", CGRect(x: 0, y: 0, width: 1512, height: 982), main: true)
    let rightOfLaptop = display("B", CGRect(x: 1512, y: 0, width: 3440, height: 1440))
    let aboveLaptop = display("B", CGRect(x: -818, y: -1440, width: 3440, height: 1440))
    #expect(
      Topology(displays: [laptop, rightOfLaptop]).fingerprint
        == Topology(displays: [laptop, aboveLaptop]).fingerprint
    )
  }

  @Test("Changing resolution is a different desk")
  func fingerprintChangesWithResolution() {
    let native = display("A", CGRect(x: 0, y: 0, width: 3440, height: 1440), main: true)
    let scaled = display("A", CGRect(x: 0, y: 0, width: 2560, height: 1080), main: true)
    #expect(Topology(displays: [native]).fingerprint != Topology(displays: [scaled]).fingerprint)
  }

  @Test("Moving the menu bar to the other display is still the same desk")
  func mainDisplayDoesNotForkTheDesk() {
    let a = display("A", CGRect(x: 0, y: 0, width: 1512, height: 982), main: true)
    let b = display("B", CGRect(x: 1512, y: 0, width: 3440, height: 1440))
    let aSecondary = display("A", CGRect(x: 0, y: 0, width: 1512, height: 982))
    let bMain = display("B", CGRect(x: 1512, y: 0, width: 3440, height: 1440), main: true)
    #expect(
      Topology(displays: [a, b]).fingerprint
        == Topology(displays: [aSecondary, bMain]).fingerprint
    )
  }

  @Test("The fingerprint is versioned, so an older identity rule is recognisable")
  func fingerprintIsVersioned() {
    let a = display("A", CGRect(x: 0, y: 0, width: 1512, height: 982), main: true)
    #expect(
      Topology(displays: [a]).fingerprint.hasPrefix(Topology.fingerprintVersion + "|")
    )
  }

  @Test("The label reads main display first, then left to right")
  func labelOrdersDisplays() {
    let laptop = display(
      "A", CGRect(x: 0, y: 0, width: 1512, height: 982), main: true, name: "Built-in Display"
    )
    let studio = display(
      "B", CGRect(x: 1512, y: 0, width: 5120, height: 2880), name: "Studio Display"
    )
    #expect(Topology(displays: [studio, laptop]).label == "Built-in Display + Studio Display")
  }

  @Test("An empty topology says so instead of producing an empty label")
  func emptyLabel() {
    #expect(Topology(displays: []).label == "No displays")
    #expect(Topology(displays: []).main == nil)
  }

  @Test("The main display is found, falling back to the only one there is")
  func mainDisplayLookup() {
    let a = display("A", CGRect(x: 0, y: 0, width: 100, height: 100))
    let b = display("B", CGRect(x: 100, y: 0, width: 100, height: 100), main: true)
    #expect(Topology(displays: [a, b]).main?.id == "B")
    #expect(Topology(displays: [a]).main?.id == "A")
    #expect(Topology(displays: [a, b]).display(id: "A")?.id == "A")
    #expect(Topology(displays: [a, b]).display(id: "C") == nil)
  }
}
