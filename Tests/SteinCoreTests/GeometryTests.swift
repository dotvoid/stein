import CoreGraphics
import Testing
@testable import SteinCore

private let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
private let laptop = CGRect(x: 0, y: 1440, width: 1512, height: 982)

@Suite("Geometry")
struct GeometryTests {
  @Test("A fraction of a display converts back to the same rectangle")
  func fractionRoundTrips() {
    let rect = CGRect(x: 1720, y: 0, width: 1720, height: 1440)
    let fraction = Geometry.fraction(of: rect, in: ultrawide)
    #expect(abs(fraction.x - 0.5) < 0.0001)
    #expect(abs(fraction.width - 0.5) < 0.0001)
    #expect(Geometry.absolute(fraction, in: ultrawide) == rect)
  }

  @Test("Fractions are relative to the display's own origin")
  func fractionIsRelativeToOrigin() {
    let rect = CGRect(x: 0, y: 1440, width: 756, height: 982)
    let fraction = Geometry.fraction(of: rect, in: laptop)
    #expect(abs(fraction.x) < 0.0001)
    #expect(abs(fraction.y) < 0.0001)
    #expect(abs(fraction.width - 0.5) < 0.0001)
  }

  @Test("A zero-sized display does not produce NaN fractions")
  func fractionSurvivesZeroSizedDisplay() {
    let fraction = Geometry.fraction(of: .zero, in: .zero)
    #expect(fraction.width == 1)
    #expect(fraction.height == 1)
  }

  @Test("A window stranded past the right edge is pulled back inside")
  func clampPullsWindowInside() {
    let stranded = CGRect(x: 4000, y: 200, width: 800, height: 600)
    #expect(
      Geometry.clamp(stranded, into: ultrawide)
        == CGRect(x: 2640, y: 200, width: 800, height: 600)
    )
  }

  @Test("A window larger than the display is shrunk to fit it")
  func clampShrinksOversizedWindow() {
    let huge = CGRect(x: 0, y: 1440, width: 3000, height: 2000)
    #expect(Geometry.clamp(huge, into: laptop) == laptop)
  }

  @Test("A window already inside is left exactly where it is")
  func clampLeavesGoodFramesAlone() {
    let fine = CGRect(x: 100, y: 120, width: 400, height: 300)
    #expect(Geometry.clamp(fine, into: ultrawide) == fine)
  }

  @Test("Verification tolerates a point of drift but not a visible offset")
  func matchesToleratesSmallDrift() {
    let target = CGRect(x: 100, y: 100, width: 800, height: 600)
    #expect(Geometry.matches(target, target.offsetBy(dx: 1, dy: -1)))
    #expect(!Geometry.matches(target, target.offsetBy(dx: 8, dy: 0)))
  }

  @Test("A straddling window belongs to the display holding most of it")
  func hostingPicksLargestOverlap() {
    let displays = [
      DisplayInfo(id: "wide", name: "Wide", bounds: ultrawide, isMain: true),
      DisplayInfo(id: "laptop", name: "Laptop", bounds: laptop, isMain: false)
    ]
    let straddling = CGRect(x: 200, y: 1340, width: 400, height: 400)
    #expect(Geometry.display(hosting: straddling, among: displays)?.id == "laptop")
  }

  @Test("A window with no overlap at all falls back to the nearest display")
  func hostingFallsBackToNearest() {
    let displays = [DisplayInfo(id: "laptop", name: "Laptop", bounds: laptop, isMain: true)]
    let orphan = CGRect(x: 5000, y: 5000, width: 300, height: 200)
    #expect(Geometry.display(hosting: orphan, among: displays)?.id == "laptop")
  }

  @Test("With no displays there is no answer to give")
  func hostingWithoutDisplays() {
    #expect(Geometry.display(hosting: .zero, among: []) == nil)
  }
}
