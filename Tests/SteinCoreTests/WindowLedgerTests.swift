import CoreGraphics
import Foundation
import Testing
@testable import SteinCore

@Suite("Window ledger")
struct WindowLedgerTests {
  private let laptop = DisplayInfo(
    id: "laptop",
    name: "Built-in Retina Display",
    bounds: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    isMain: true
  )
  private let external = DisplayInfo(
    id: "dell",
    name: "DELL U3219Q",
    bounds: CGRect(x: -1028, y: -2160, width: 3840, height: 2160),
    isMain: false
  )

  private func window(
    _ name: String,
    on display: DisplayInfo,
    at offset: CGPoint = CGPoint(x: 20, y: 20),
    id: UInt32? = nil
  ) -> WindowSnapshot {
    WindowSnapshot(
      bundleID: "com.example.\(name)",
      appName: name,
      // Stable per name, so the same app in two measurements is the same window.
      windowID: id ?? UInt32(name.utf8.reduce(7) { ($0 &* 31 &+ UInt32($1)) % 60_000 } + 1),
      title: name,
      ordinal: 0,
      frame: CGRect(
        x: display.bounds.minX + offset.x,
        y: display.bounds.minY + offset.y,
        width: 900,
        height: 700
      ),
      display: display
    )
  }

  @Test("The first measurement is a baseline and nothing else")
  func firstObservationAuthorsNothing() {
    var ledger = WindowLedger()
    let verdict = ledger.observe([window("mail", on: laptop)], userWasActive: true)
    #expect(!verdict.hasChanges)
    #expect(ledger.hasBaseline)
  }

  @Test("A window the user dragged is authored")
  func userMoveIsAuthored() {
    var ledger = WindowLedger()
    ledger.seed([window("mail", on: laptop)])
    let verdict = ledger.observe(
      [window("mail", on: laptop, at: CGPoint(x: 400, y: 300))],
      userWasActive: true
    )
    #expect(verdict.authored.count == 1)
    #expect(verdict.displaced.isEmpty)
  }

  /// The bug, in one test. Sleeping with the external display attached
  /// disconnects it, macOS piles its windows onto the laptop screen, and nobody
  /// was there to do it.
  @Test("A pile that appeared with nobody here authors nothing")
  func pileIsNotAuthored() {
    var ledger = WindowLedger()
    ledger.seed([
      window("chrome", on: external),
      window("zed", on: external),
      window("mail", on: laptop)
    ])
    let verdict = ledger.observe(
      [
        window("chrome", on: laptop, at: CGPoint(x: 0, y: 39)),
        window("zed", on: laptop, at: CGPoint(x: 0, y: 39)),
        window("mail", on: laptop)
      ],
      userWasActive: false
    )
    #expect(verdict.authored.isEmpty)
    #expect(!verdict.hasChanges)
    #expect(verdict.displaced.count == 2)
  }

  /// The other half of the bug: the lock screen hides nearly the whole desk, so
  /// almost every window reads as closed.
  @Test("Windows that vanish with nobody here are not treated as closed")
  func hiddenWindowsAreNotClosed() {
    var ledger = WindowLedger()
    ledger.seed([
      window("chrome", on: laptop),
      window("zed", on: laptop),
      window("mail", on: laptop)
    ])
    let verdict = ledger.observe([window("mail", on: laptop)], userWasActive: false)
    #expect(verdict.closed.isEmpty)
    #expect(!verdict.hasChanges)
  }

  @Test("A window the user closed is closed")
  func userCloseIsRecorded() {
    var ledger = WindowLedger()
    ledger.seed([window("chrome", on: laptop), window("mail", on: laptop)])
    let verdict = ledger.observe([window("mail", on: laptop)], userWasActive: true)
    #expect(verdict.closed.count == 1)
    #expect(verdict.closed.first?.appName == "chrome")
  }

  @Test("Dragging one window out of a pile authors only that window")
  func onlyTheTouchedWindowIsAuthored() {
    var ledger = WindowLedger()
    let piled = [
      window("chrome", on: laptop),
      window("zed", on: laptop),
      window("mail", on: laptop)
    ]
    ledger.seed(piled)
    let verdict = ledger.observe(
      [window("chrome", on: external), piled[1], piled[2]],
      userWasActive: true
    )
    #expect(verdict.authored.count == 1)
    #expect(verdict.authored.first?.appName == "chrome")
  }

  @Test("A desk nobody touched produces nothing to write")
  func idleDeskIsSilent() {
    var ledger = WindowLedger()
    let desk = [window("chrome", on: external), window("mail", on: laptop)]
    ledger.seed(desk)
    #expect(!ledger.observe(desk, userWasActive: true).hasChanges)
  }

  @Test("A window that only jitters a point or two has not moved")
  func subPixelDriftIsIgnored() {
    var ledger = WindowLedger()
    ledger.seed([window("chrome", on: laptop, at: CGPoint(x: 20, y: 20))])
    let verdict = ledger.observe(
      [window("chrome", on: laptop, at: CGPoint(x: 21, y: 21))],
      userWasActive: true
    )
    #expect(!verdict.hasChanges)
  }

  // MARK: - Other Spaces

  /// The Accessibility API reports nothing about other Spaces, so "not in view"
  /// arrives looking exactly like "closed". The window-number list is the only
  /// public thing that can tell them apart.
  @Test("A window that is out of view but still exists is not closed")
  func hiddenButExistingIsNotClosed() {
    var ledger = WindowLedger()
    let chrome = window("chrome", on: external)
    let zed = window("zed", on: external)
    let mail = window("mail", on: laptop)
    ledger.seed([chrome, zed, mail])

    // Switched Space: only mail is in view, but all three still exist.
    let verdict = ledger.observe(
      [mail],
      existing: [chrome.windowID!, zed.windowID!, mail.windowID!],
      userWasActive: true
    )
    #expect(!verdict.hasChanges)
    #expect(verdict.closed.isEmpty)
  }

  @Test("A window that is out of view and gone from the window list has closed")
  func goneIsClosed() {
    var ledger = WindowLedger()
    let chrome = window("chrome", on: external)
    let mail = window("mail", on: laptop)
    ledger.seed([chrome, mail])

    let verdict = ledger.observe([mail], existing: [mail.windowID!], userWasActive: true)
    #expect(verdict.closed.count == 1)
    #expect(verdict.closed.first?.appName == "chrome")
  }

  /// The existence check has to hold even when the baseline was not re-taken -
  /// which is what made this a latent bug rather than a theoretical one: pausing
  /// learning, switching Space and unpausing skipped the re-baseline entirely.
  @Test("Existence protects a Space switch with no baseline reset in between")
  func existenceProtectsWithoutRebaseline() {
    var ledger = WindowLedger()
    let spaceA = [window("chrome", on: laptop, id: 11), window("safari", on: laptop, id: 12)]
    let spaceB = [window("kitty", on: laptop, id: 21)]
    ledger.seed(spaceA)

    let all: Set<UInt32> = [11, 12, 21]
    let verdict = ledger.observe(spaceB, existing: all, userWasActive: true)
    #expect(verdict.closed.isEmpty)
  }

  // MARK: - First sightings

  /// A window Stein has never measured must not be credited to the user, however
  /// active they were. Arriving at a Space is user activity, and the windows
  /// there may have been piled by macOS while it was out of sight - crediting
  /// them would overwrite the good layout with the pile.
  @Test("A window seen for the first time is baselined, not authored")
  func firstSightingIsNotAuthored() {
    var ledger = WindowLedger()
    ledger.seed([window("mail", on: laptop, id: 1)])
    let verdict = ledger.observe(
      [window("mail", on: laptop, id: 1), window("kitty", on: external, id: 2)],
      existing: [1, 2],
      userWasActive: true
    )
    #expect(verdict.authored.isEmpty)

    // Once measured, moving it does count.
    let moved = window("kitty", on: laptop, at: CGPoint(x: 700, y: 200), id: 2)
    let second = ledger.observe(
      [window("mail", on: laptop, id: 1), moved],
      existing: [1, 2],
      userWasActive: true
    )
    #expect(second.authored.count == 1)
    #expect(second.authored.first?.appName == "kitty")
  }

  @Test("Resetting drops the baseline, so the next measurement re-establishes it")
  func resetClearsBaseline() {
    var ledger = WindowLedger()
    ledger.seed([window("mail", on: laptop)])
    ledger.reset()
    #expect(!ledger.hasBaseline)
    let verdict = ledger.observe(
      [window("mail", on: laptop, at: CGPoint(x: 900, y: 900))],
      userWasActive: true
    )
    #expect(!verdict.hasChanges)
  }
}
