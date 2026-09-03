import AppKit
import CoreGraphics
import Foundation
import SteinCore

/// What the menu needs to know. Snapshotted onto the main thread so the UI never
/// reaches into engine state.
struct Status {
  var trusted = false
  var paused = false
  var settling = false
  var topologyLabel = ""
  var hasLayoutForCurrentDesk = false
  var canUndo = false
  var receipts = Receipts()
}

/// The part of Stein that decides when to look and when to act.
///
/// Two jobs, and the ordering between them is the entire design:
///
/// 1. While displays are steady, learn. Snapshot the desk on a timer and file it
///    under the current display arrangement.
/// 2. When displays change, stop learning immediately, wait for macOS to finish
///    rearranging, then put the remembered layout back.
///
/// Step 2 has to freeze step 1 before macOS starts moving windows. The moment a
/// display disconnects, every window on it is piled onto whatever screen is left -
/// and a learner that keeps learning through that will happily record the pile as
/// the layout for the laptop-only desk, overwriting the good one. That single race
/// is what separates a layout restorer that works from one that slowly eats your
/// layouts.
///
/// Which it did, and freezing at the right moment turned out not to be enough,
/// because the pile is still there when the freeze lifts. So step 1 is narrower
/// than it looks:
///
/// 1a. Learn what the *user* changed, not what the desk looks like.
///
/// Every window's remembered position is its own fact, changed only by evidence
/// about that window: it moved, while a human was here to move it. macOS piling
/// windows onto the laptop screen satisfies neither test, so a pile is not a
/// layout, is not learned, and cannot displace what is on file - for as long as
/// it lasts, with no timer to outlive and nothing to ask the user. `WindowLedger`
/// draws that line; `UserPresence` and `Session` are the signals it draws it
/// from.
///
/// The layout each write replaces is kept as well. The rules above are the honest
/// ones available, which means one of them will eventually be wrong, and a silent
/// write nobody can take back is the thing that actually loses somebody a desk.
final class Coordinator {
  private let store: Store
  private let queue = DispatchQueue(label: "app.stein.engine", qos: .utility)

  /// How often to look at the desk while it is steady.
  private let snapshotInterval: TimeInterval = 2.0
  /// How long the display configuration must be quiet before it counts as settled.
  /// macOS emits a burst of reconfiguration events - arrangement, mode, mirroring -
  /// and restoring into the middle of the burst just gets undone.
  private let settleDelay: TimeInterval = 1.6
  /// How long to wait after a wake before believing the display list.
  ///
  /// Longer than `settleDelay` because an external display comes back over a
  /// renegotiated link and can take several seconds to reappear. Settling on the
  /// built-in screen alone restores the wrong desk and then has to be redone.
  private let wakeSettleDelay: TimeInterval = 6.0
  /// Grace period after a manual restore before learning resumes, so the layout
  /// that gets learned is the restored one and not a half-finished intermediate.
  private let postRestoreQuiet: TimeInterval = 2.5
  /// Grace period after a display change, which is a different animal.
  ///
  /// Apps go on reflowing and repositioning their own windows for a long time
  /// after macOS says the displays have settled - long enough that the old 2.5
  /// seconds routinely had the learner recording a desk still mid-rearrangement.
  private let postDisplayChangeQuiet: TimeInterval = 20.0
  /// How long to let a Space settle before seating it. Short: the windows are
  /// already there, only the compositor has to catch up.
  private let spaceSettleDelay: TimeInterval = 0.2
  /// How long after the first sign of a display change to try a restore, without
  /// waiting for the configuration to stop changing.
  ///
  /// The settle delay is the honest deadline - macOS reports transient
  /// arrangements and a restore into the middle of one gets undone - but on a
  /// slow external link the whole burst can run for several seconds, and windows
  /// sitting in a pile for that long reads as Stein having failed. A restore
  /// costs about 80ms and asks for a frame a window is often already at, so
  /// trying early and correcting at the settle is nearly free.
  private let earlyRestoreDelay: TimeInterval = 0.5

  private var timer: DispatchSourceTimer?
  private var settleWorkItem: DispatchWorkItem?
  private var earlyWorkItem: DispatchWorkItem?

  // Queue-confined state.
  private var topology = Topology(displays: [])
  private var paused = false
  private var settling = false
  private var learningSuspendedUntil = Date.distantPast
  private var lastDigest: UInt64 = 0
  /// Where every window was at the last measurement, and therefore which of the
  /// differences since are the user's doing.
  private var ledger = WindowLedger()
  /// A desk that is currently mid-change, and whether anybody is behind it.
  private struct Motion {
    var userWasActive: Bool
  }
  private var motion: Motion?
  /// When the previous tick ran, which bounds the window the presence check has
  /// to ask about.
  private var lastTickAt: Date?
  /// True between going to sleep and waking up, or while the screens are off.
  private var asleep = false
  /// Where the last restore found the windows it moved.
  private var undo = UndoRecord()
  /// Counts restore episodes. A display change, a Space change and each manual
  /// command start one; the follow-up passes of a restore belong to it. Anything
  /// scheduled by an episode checks this before running, so a burst of display
  /// events cannot leave stale passes rearranging a desk that has moved on.
  private var episode = 0

  /// Called on the main thread whenever the menu should redraw.
  var onStatus: ((Status) -> Void)?

  init(store: Store) {
    self.store = store
  }

  // MARK: - Lifecycle

  func start() {
    registerDisplayCallbacks()
    queue.async { [weak self] in
      guard let self else { return }
      topology = MainThread.sync { Displays.current() }
      // Launching is not a display change, but it is the same situation: the desk
      // is however it was left, which is a baseline rather than a decision.
      if store.layout(for: topology.fingerprint) == nil {
        learn(userWasActive: false)
      } else {
        establishBaseline()
      }
      publish()
    }
    startTimer()
  }

  private func startTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + snapshotInterval, repeating: snapshotInterval)
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    self.timer = timer
  }

  private func registerDisplayCallbacks() {
    let context = Unmanaged.passUnretained(self).toOpaque()
    CGDisplayRegisterReconfigurationCallback({ _, flags, context in
      guard let context else { return }
      let coordinator = Unmanaged<Coordinator>.fromOpaque(context).takeUnretainedValue()
      if flags.contains(.beginConfigurationFlag) {
        // Earliest possible warning, before the window server moves anything.
        coordinator.freeze()
      } else {
        coordinator.displaysChanged()
      }
    }, context)

    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.displaysChanged()
    }

    let workspace = NSWorkspace.shared.notificationCenter
    // Sleeping with an external display attached disconnects it, and everything
    // on it is piled onto the built-in screen. That happens while the machine is
    // on its way down, too late for any callback Stein could act on, so the only
    // safe move is to stop looking before it starts.
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
      workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.wentToSleep()
      }
    }
    // Waking frequently means the desk changed while nobody was looking, so a
    // system wake is worth a full settle-and-restore.
    workspace.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.wokeUp()
    }
    // Screens waking is not. They sleep on an idle timer several times a day
    // without a single display being added or removed, and restoring every time
    // would mean a toast every time saying nothing happened. Displays that really
    // did change announce themselves through the reconfiguration callback, and
    // `tick` catches any that slip through.
    workspace.addObserver(
      forName: NSWorkspace.screensDidWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.resumeWithoutRestoring()
    }

    // Arriving at a Space is the first chance to seat the windows on it, because
    // it is the first moment they can be measured and verified. A restore on a
    // display change can only ever reach the Space that happened to be in front
    // of the user; the rest are put back as they are visited.
    workspace.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.spaceChanged()
    }

    // The lock screen is the other blind spot, and a worse one: it does not look
    // like a blind spot. `Session.isActive` is checked on every tick as the
    // authority; these two just get the timing right at the edges.
    let distributed = DistributedNotificationCenter.default()
    distributed.addObserver(
      forName: Notification.Name("com.apple.screenIsLocked"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.wentToSleep()
    }
    distributed.addObserver(
      forName: Notification.Name("com.apple.screenIsUnlocked"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.resumeWithoutRestoring()
    }
  }

  // MARK: - Learning

  /// One pass over the desk.
  ///
  /// The cheap digest does the watching; a full Accessibility scan only happens
  /// when the digest says something actually moved, and only once it has stopped
  /// moving. The question that pass has to answer is not "what does the desk look
  /// like" but "what did the *user* change", so the answer to "was anybody here?"
  /// is collected while the desk is still in motion, not afterwards.
  private func tick() {
    // Updated before every guard below, because the gap between ticks is what
    // bounds the presence question, and a gap Stein slept through must not be
    // mistaken for one it was watching.
    let now = Date()
    let sincePreviousTick = lastTickAt
    lastTickAt = now

    guard !paused, !settling, !asleep, AX.isTrusted else { return }

    guard Session.isActive else {
      // Nothing measured through a lock screen is worth having, and nothing
      // measured before one can be compared with anything measured after it.
      motion = nil
      ledger.reset()
      return
    }

    let current = MainThread.sync { Displays.current() }
    if current.fingerprint != topology.fingerprint {
      // A change nobody told us about (or one whose callback we missed).
      // Treat it exactly like a reported one rather than learning through it.
      freeze()
      displaysChanged()
      return
    }

    guard Date() >= learningSuspendedUntil else { return }

    let digest = WindowScanner.deskDigest()
    let active = userWasHere(since: sincePreviousTick, now: now)

    if digest != lastDigest {
      // The desk is in motion. Note whether a human is behind it and wait for it
      // to stop: measuring mid-drag would record a window halfway to where it is
      // going.
      lastDigest = digest
      motion = Motion(userWasActive: (motion?.userWasActive ?? false) || active)
      return
    }

    // Still for a whole tick. If nothing moved since the last measurement there
    // is nothing to measure - which on an idle desk is every tick, and the reason
    // the timer costs nothing.
    guard let settledMotion = motion else { return }
    motion = nil
    learn(userWasActive: settledMotion.userWasActive)
  }

  /// Whether a human touched the machine during the interval that just ended.
  ///
  /// An interval much longer than a tick is one Stein was not actually watching -
  /// asleep, or blocked on a long restore - and the idle clock cannot say where in
  /// it the input landed. Attributing a window move to the user on the strength of
  /// a keystroke that might have come hours earlier is exactly the mistake this is
  /// here to prevent, so an interval that long answers "no".
  private func userWasHere(since previousTick: Date?, now: Date) -> Bool {
    guard let previousTick else { return false }
    guard now.timeIntervalSince(previousTick) <= snapshotInterval * 3 else { return false }
    return UserPresence.active(since: previousTick, now: now)
  }

  /// Writes down what changed, and only what the user changed.
  private func learn(userWasActive: Bool) {
    guard AX.isTrusted, !topology.displays.isEmpty else { return }
    let fingerprint = topology.fingerprint
    let measurement = WindowScanner.measure(topology: topology)

    // A full scan takes long enough that displays can change during it. If they
    // did, this measurement describes a desk that no longer exists.
    guard MainThread.sync({ Displays.current() }).fingerprint == fingerprint else { return }

    guard let existing = store.layout(for: fingerprint) else {
      adoptAsFirstLayout(measurement)
      return
    }

    var verdict = ledger.observe(
      measurement.observable,
      existing: measurement.existingIDs,
      userWasActive: userWasActive
    )
    // A window with no remembered position is not a window whose position the
    // user chose to leave alone - it is one Stein has never written down. Taking
    // it at face value costs nothing, and without it a Space the user has never
    // rearranged stays unremembered and therefore unrestorable.
    verdict.adopted = existing.unknownWindows(among: measurement.observable)
      .filter { !verdict.authored.contains($0) }
    guard verdict.hasChanges else { return }

    let merged = existing.merging(
      verdict,
      topologyLabel: topology.label,
      capturedAt: Date()
    )
    if store.remember(merged) {
      store.recordLayoutWrite()
      publish()
    }
  }

  /// A desk Stein has never seen before has nothing to lose, so whatever is on it
  /// becomes the starting point. Provisional by nature, and refined from then on
  /// one authored window at a time.
  private func adoptAsFirstLayout(_ measurement: WindowScanner.Measurement) {
    guard !measurement.observable.isEmpty else { return }
    ledger.seed(measurement.observable)
    let snapshot = LayoutSnapshot(
      fingerprint: topology.fingerprint,
      topologyLabel: topology.label,
      capturedAt: Date(),
      windows: measurement.observable
    )
    if store.remember(snapshot) {
      store.recordLayoutWrite()
      publish()
    }
  }

  /// Measures the desk purely to give the ledger something to compare against.
  ///
  /// Called after a display change, where the first thing Stein sees is the
  /// aftermath of something macOS did. Seeding rather than learning is the whole
  /// point: the aftermath becomes the baseline, and none of it is mistaken for a
  /// decision anybody made.
  private func establishBaseline() {
    guard AX.isTrusted, !topology.displays.isEmpty else { return }
    let fingerprint = topology.fingerprint
    let measurement = WindowScanner.measure(topology: topology)
    guard MainThread.sync({ Displays.current() }).fingerprint == fingerprint else { return }
    ledger.seed(measurement.observable)
    lastDigest = WindowScanner.deskDigest()
    motion = nil
    adoptUnknownWindows(measurement.observable)
  }

  /// Writes down the windows the layout has no opinion about yet.
  ///
  /// Done here rather than left to the learner because taking a baseline is what
  /// consumes the change that brought Stein here: after a Space switch the desk
  /// digest is recorded as the new normal, so the learner sees nothing to look at
  /// and a Space full of unremembered windows would stay unremembered until the
  /// user happened to move something.
  ///
  /// Safe at any moment, however chaotic, because it only ever adds a position
  /// where none was stored. It cannot overwrite one.
  private func adoptUnknownWindows(_ observable: [WindowSnapshot]) {
    guard let existing = store.layout(for: topology.fingerprint) else { return }
    let unknown = existing.unknownWindows(among: observable)
    guard !unknown.isEmpty else { return }
    let merged = existing.merging(
      WindowLedger.Verdict(adopted: unknown),
      topologyLabel: topology.label
    )
    if store.remember(merged) {
      store.recordLayoutWrite()
      publish()
    }
  }


  // MARK: - Sleep and lock

  private func wentToSleep() {
    queue.async { [weak self] in
      guard let self else { return }
      asleep = true
      forgetDeskHistory()
      publish()
    }
  }

  private func wokeUp() {
    queue.async { [weak self] in
      guard let self else { return }
      asleep = false
      forgetDeskHistory()
    }
    displaysChanged(after: wakeSettleDelay)
  }

  /// Starts watching again after an interruption that was not a display change.
  ///
  /// Unlocking, or the screens coming back on, is the first moment Stein can see
  /// the desk again - and what it sees is whatever the interruption left behind
  /// rather than a layout anybody chose. So: no restore, since nothing says the
  /// displays moved, but enough quiet that the learner does not mistake the
  /// leftovers for the layout.
  private func resumeWithoutRestoring() {
    queue.async { [weak self] in
      guard let self else { return }
      asleep = false
      forgetDeskHistory()
      learningSuspendedUntil = Date().addingTimeInterval(postDisplayChangeQuiet)
      publish()
    }
  }

  /// Seats the windows that just came into view.
  ///
  /// Deliberately quiet. This runs every time the user changes Space, which on a
  /// tidy desk means finding everything already where it belongs - so it only
  /// speaks up when it actually moved something.
  private func spaceChanged() {
    queue.asyncAfter(deadline: .now() + spaceSettleDelay) { [weak self] in
      guard let self, !paused, !settling, !asleep, AX.isTrusted, Session.isActive else { return }
      let current = MainThread.sync { Displays.current() }
      guard current.fingerprint == topology.fingerprint,
            let layout = store.layout(for: current.fingerprint) else { return }
      episode += 1
      let outcome = RestoreEngine.restore(
        windows: layout.windows,
        topology: current,
        kind: .spaceChange,
        topologyLabel: current.label
      )
      finish(outcome, announce: outcome.report.totalMoved > 0)
      // An app on the Space just arrived at can be as unready as one on a desk
      // that just changed, and until now a Space restore got no second chance.
      if needsAnotherPass(outcome.report) {
        scheduleRestorePass(
          layout.windows,
          topology: current,
          kind: .spaceChange,
          attempt: 0
        )
      }
    }
  }

  /// Drops every cached impression of the desk, so nothing measured before an
  /// interruption can pair up with something measured after it.
  private func forgetDeskHistory() {
    lastDigest = 0
    motion = nil
    ledger.reset()
  }

  // MARK: - Display changes

  private func freeze() {
    queue.async { [weak self] in
      guard let self else { return }
      settling = true
      forgetDeskHistory()
      publish()
    }
  }

  private func displaysChanged(after delay: TimeInterval? = nil) {
    let wait = delay ?? settleDelay
    queue.async { [weak self] in
      guard let self else { return }
      settling = true
      // Every event pushes the settle deadline out, so the authoritative restore
      // happens once the configuration has actually stopped moving.
      settleWorkItem?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.settled() }
      settleWorkItem = work
      queue.asyncAfter(deadline: .now() + wait, execute: work)

      // The early pass is scheduled from the *first* event of the burst and
      // deliberately not pushed back by the rest, because being pushed back is
      // exactly the thing that made the wait feel broken.
      guard earlyWorkItem == nil else { return }
      episode += 1
      let early = DispatchWorkItem { [weak self] in self?.earlyRestore() }
      earlyWorkItem = early
      queue.asyncAfter(deadline: .now() + earlyRestoreDelay, execute: early)
    }
  }

  /// A first attempt, before the display configuration has finished settling.
  ///
  /// Says nothing to the user: the settle pass is the authority and does the
  /// announcing. If this one got there first, the settle pass finds the windows
  /// already right and reports that.
  private func earlyRestore() {
    earlyWorkItem = nil
    guard !paused, !asleep, AX.isTrusted, Session.isActive else { return }
    let current = MainThread.sync { Displays.current() }
    guard !current.displays.isEmpty,
          let layout = store.layout(for: current.fingerprint) else { return }
    topology = current
    restore(layout.windows, topology: current, kind: .displayChange, announce: false)
  }

  private func settled() {
    earlyWorkItem?.cancel()
    earlyWorkItem = nil
    let current = MainThread.sync { Displays.current() }
    topology = current
    settling = false
    // Reaching a settled configuration is the one unambiguous "the world is
    // steady again" moment, so it also clears a sleep flag whose matching wake
    // notification never arrived.
    asleep = false
    forgetDeskHistory()
    learningSuspendedUntil = Date().addingTimeInterval(postDisplayChangeQuiet)

    guard AX.isTrusted, !current.displays.isEmpty else {
      publish()
      return
    }

    guard let layout = store.layout(for: current.fingerprint) else {
      // First time at this desk. Adopt what is on screen as the starting point;
      // there is nothing to put back and nothing to announce.
      learn(userWasActive: false)
      MainThread.sync {
        Toast.shared.show(
          title: current.label,
          detail: "New desk - learning this layout"
        )
      }
      publish()
      return
    }

    restore(layout.windows, topology: current, kind: .displayChange)
  }

  /// Restores now, and schedules follow-up passes for anything that did not land.
  ///
  /// The apps that need a second pass are the ones reacting to the same display
  /// change Stein is: reflowing, restoring their own window state, coming back
  /// from a wake. They are not ready at 0.9 seconds and there is no single later
  /// moment at which they all are, so the passes spread out instead of guessing
  /// one.
  ///
  /// They are *scheduled* rather than slept through, which the first version got
  /// wrong. Sleeping held the engine queue for up to 31 seconds, and everything
  /// the queue is for - noticing a display change, seating a Space the user just
  /// switched to, learning - waited behind it. The result of the first pass is
  /// reported immediately, so the user hears about it at once either way.
  private func restore(
    _ windows: [WindowSnapshot],
    topology: Topology,
    kind: RestoreReport.Kind,
    announce: Bool = true
  ) {
    let outcome = RestoreEngine.restore(
      windows: windows,
      topology: topology,
      kind: kind,
      topologyLabel: topology.label
    )
    finish(outcome, announce: announce)
    guard needsAnotherPass(outcome.report) else { return }
    scheduleRestorePass(windows, topology: topology, kind: kind, attempt: 0)
  }

  private func scheduleRestorePass(
    _ windows: [WindowSnapshot],
    topology: Topology,
    kind: RestoreReport.Kind,
    attempt: Int
  ) {
    guard attempt < Coordinator.retryDelays.count else { return }
    let mine = episode
    queue.asyncAfter(deadline: .now() + Coordinator.retryDelays[attempt]) { [weak self] in
      guard let self, mine == episode else { return }
      guard !paused, !asleep, AX.isTrusted, Session.isActive else { return }
      // The desk this pass was written for may not be the desk any more.
      guard MainThread.sync({ Displays.current() }).fingerprint == topology.fingerprint else {
        return
      }
      let outcome = RestoreEngine.restore(
        windows: windows,
        topology: topology,
        kind: kind,
        topologyLabel: topology.label
      )
      // Only worth reporting when this pass actually rescued something.
      if outcome.report.totalMoved > 0 {
        finish(outcome)
      }
      guard needsAnotherPass(outcome.report) else { return }
      scheduleRestorePass(windows, topology: topology, kind: kind, attempt: attempt + 1)
    }
  }

  /// A window that refused to move may yet move; a window whose app is closed
  /// will not. Windows waiting on another Space are neither - they are seated
  /// when the user goes there, and are not what these passes are for.
  private func needsAnotherPass(_ report: RestoreReport) -> Bool {
    report.failed > 0 || report.wasIneffective
  }

  /// Spread over about half a minute, which covers an app still starting up
  /// without leaving the user watching a desk rearrange itself indefinitely.
  private static let retryDelays: [TimeInterval] = [0.9, 2, 4, 8, 16]

  private func finish(_ outcome: RestoreOutcome, announce: Bool = true) {
    store.record(outcome.report)
    // Undo is one-shot on purpose. Offering to undo an undo turns one clear
    // action into a toggle nobody can keep track of.
    if outcome.report.kind == .undo {
      undo.clear()
    } else {
      undo.record(outcome.undo, episode: episode)
    }

    let quiet = outcome.report.kind == .displayChange ? postDisplayChangeQuiet : postRestoreQuiet
    learningSuspendedUntil = Date().addingTimeInterval(quiet)
    // The desk Stein just rearranged is the ledger's new baseline, not a set of
    // changes to attribute to anybody. Nothing here needs to hold the learner off
    // afterwards: a restore that failed leaves windows where macOS left them, and
    // windows where macOS left them are never authored, so there is nothing for
    // the learner to get wrong.
    forgetDeskHistory()
    establishBaseline()
    if announce {
      MainThread.sync { Toast.shared.report(outcome.report) }
    }
    publish()
  }

  // MARK: - Commands

  /// The user's own "remember this", and therefore the one write that answers to
  /// nobody: the whole desk, as it is, attributed to the person who asked.
  ///
  /// Not a recovery mechanism - nothing should need recovering - just the short
  /// way to say "this, now" instead of arranging windows and waiting to be
  /// noticed.
  func snapshotNow() {
    queue.async { [weak self] in
      guard let self else { return }
      asleep = false
      forgetDeskHistory()
      topology = MainThread.sync { Displays.current() }
      let measurement = WindowScanner.measure(topology: topology)
      guard !measurement.observable.isEmpty else {
        MainThread.sync {
          Toast.shared.show(title: "Nothing to snapshot", detail: "No placeable windows found")
        }
        return
      }

      // Everything in view is taken at face value - the user asked - but this is
      // still a merge, because the windows on the user's other Spaces are not in
      // view and replacing the layout wholesale would forget them.
      let verdict = WindowLedger.Verdict(authored: measurement.observable)
      let snapshot = store.layout(for: topology.fingerprint)?.merging(
        verdict,
        topologyLabel: topology.label
      ) ?? LayoutSnapshot(
        fingerprint: topology.fingerprint,
        topologyLabel: topology.label,
        capturedAt: Date(),
        windows: measurement.observable
      )

      store.remember(snapshot)
      store.recordLayoutWrite()
      ledger.seed(measurement.observable)
      lastDigest = WindowScanner.deskDigest()
      let seated = measurement.observable.count
      let waiting = snapshot.windows.count - seated
      MainThread.sync {
        Toast.shared.show(
          title: snapshot.topologyLabel,
          detail: waiting > 0
            ? "Remembered \(seated) windows · \(waiting) kept from other Spaces"
            : "Remembered \(seated) windows"
        )
      }
      publish()
    }
  }

  func restoreNow() {
    queue.async { [weak self] in
      guard let self else { return }
      let current = MainThread.sync { Displays.current() }
      topology = current
      guard let layout = store.layout(for: current.fingerprint) else {
        MainThread.sync {
          Toast.shared.show(
            title: current.label,
            detail: "No layout remembered for this desk yet"
          )
        }
        return
      }
      episode += 1
      restore(layout.windows, topology: current, kind: .manual)
    }
  }

  /// Puts the windows of the last restore back where they were found.
  ///
  /// The safety valve for the whole design. Stein moves windows without being
  /// asked, so there has to be one keystroke that says "no, not that".
  func undoLastRestore() {
    queue.async { [weak self] in
      guard let self else { return }
      guard !undo.isEmpty else {
        MainThread.sync {
          Toast.shared.show(title: "Nothing to undo", detail: "No restore to take back")
        }
        return
      }
      let windows = undo.windows
      let current = MainThread.sync { Displays.current() }
      topology = current
      episode += 1
      restore(windows, topology: current, kind: .undo)
    }
  }

  func forgetAllLayouts() {
    queue.async { [weak self] in
      guard let self else { return }
      store.forgetAllLayouts()
      publish()
    }
  }

  var isPaused: Bool {
    queue.sync { paused }
  }

  func setPaused(_ value: Bool) {
    queue.async { [weak self] in
      guard let self else { return }
      paused = value
      publish()
    }
  }

  func refresh() {
    queue.async { [weak self] in self?.publish() }
  }

  /// Snapshot engine state and hand it to the main thread.
  private func publish() {
    let status = Status(
      trusted: AX.isTrusted,
      paused: paused,
      settling: settling,
      topologyLabel: topology.label,
      hasLayoutForCurrentDesk: store.layout(for: topology.fingerprint) != nil,
      canUndo: !undo.isEmpty,
      receipts: store.receipts
    )
    DispatchQueue.main.async { [weak self] in
      self?.onStatus?(status)
    }
  }
}
