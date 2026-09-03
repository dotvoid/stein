import Foundation

/// A single JSON file on disk, written atomically.
///
/// Atomic because the most likely moment for the machine to be interrupted is
/// exactly when Stein is writing: the lid is closing, the dock is being pulled.
public final class JSONFile<Value: Codable> {
  private let url: URL
  private let queue = DispatchQueue(label: "app.stein.jsonfile")

  /// Long enough that no write anywhere can still be using the file. A temporary
  /// this old belonged to a process that is no longer running.
  // Computed rather than stored: a generic type cannot hold a static.
  static var abandonedAfter: TimeInterval { 60 }

  public init(url: URL) {
    self.url = url
    queue.sync { sweepAbandonedTemporaries() }
  }

  /// Removes temporary files left behind by a write that never finished.
  ///
  /// `save` writes to a uniquely named sibling and swaps it into place, so a write
  /// interrupted between the two - the process quit, the machine slept - leaves
  /// the sibling behind. Nothing else ever removed them, and they collected in a
  /// folder the menu invites the user to open.
  ///
  /// Startup is the only moment this is needed: a temporary can only be abandoned
  /// by a process dying, and a process that died is followed by one that starts.
  /// The age check is there so that a write under way in some other process is
  /// left alone; its files are none of this one's business.
  private func sweepAbandonedTemporaries() {
    let directory = url.deletingLastPathComponent()
    let prefix = url.lastPathComponent + ".tmp-"
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-JSONFile.abandonedAfter)
    for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
      let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      guard let modified, modified < cutoff else { continue }
      try? FileManager.default.removeItem(at: entry)
    }
  }

  public func load() -> Value? {
    queue.sync {
      guard let data = try? Data(contentsOf: url) else { return nil }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try? decoder.decode(Value.self, from: data)
    }
  }

  public func save(_ value: Value) {
    queue.sync {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      guard let data = try? encoder.encode(value) else { return }
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let temporary = url.appendingPathExtension("tmp-\(UInt32.random(in: 0...UInt32.max))")
      do {
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
      } catch {
        try? FileManager.default.removeItem(at: temporary)
        try? data.write(to: url, options: .atomic)
      }
    }
  }
}

/// Everything Stein remembers, on disk, in plain JSON you can read and delete.
public final class Store {
  /// How many desks to remember. Well past any realistic number of docks, hotel
  /// TVs and conference-room projectors, and small enough to stay tidy.
  public static let maximumRememberedDesks = 32

  public let directory: URL
  private let layoutsFile: JSONFile<[String: LayoutSnapshot]>
  private let receiptsFile: JSONFile<Receipts>

  private var layouts: [String: LayoutSnapshot]
  private var receiptsStorage: Receipts

  public init(directory: URL? = nil) {
    let base = directory ?? Store.defaultDirectory
    self.directory = base
    layoutsFile = JSONFile(url: base.appendingPathComponent("layouts.json"))
    receiptsFile = JSONFile(url: base.appendingPathComponent("receipts.json"))
    layouts = layoutsFile.load() ?? [:]
    receiptsStorage = receiptsFile.load() ?? Receipts()
    discardForeignVersions()
  }

  /// Drops layouts filed under an older fingerprint rule.
  ///
  /// They can never match again, and keeping them would leave the desk count
  /// reporting memory that will never be used.
  private func discardForeignVersions() {
    let prefix = Topology.fingerprintVersion + "|"
    let current = layouts.filter { $0.key.hasPrefix(prefix) }
    guard current.count != layouts.count else { return }
    layouts = current
    layoutsFile.save(layouts)
  }

  public static var defaultDirectory: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    let base = support.first ?? URL(fileURLWithPath: NSHomeDirectory())
    return base.appendingPathComponent("Stein", isDirectory: true)
  }

  // MARK: - Layouts

  public func layout(for fingerprint: String) -> LayoutSnapshot? {
    layouts[fingerprint]
  }

  public var rememberedDesks: [LayoutSnapshot] {
    layouts.values.sorted { $0.capturedAt > $1.capturedAt }
  }

  /// Stores the snapshot unless it is identical to what is already filed, in
  /// which case there is nothing to write and the timestamp is left alone.
  @discardableResult
  public func remember(_ snapshot: LayoutSnapshot) -> Bool {
    if let existing = layouts[snapshot.fingerprint], existing.describesSameDesk(as: snapshot) {
      return false
    }
    layouts[snapshot.fingerprint] = snapshot
    prune()
    layoutsFile.save(layouts)
    return true
  }

  public func forgetLayout(fingerprint: String) {
    layouts[fingerprint] = nil
    layoutsFile.save(layouts)
  }

  public func forgetAllLayouts() {
    layouts = [:]
    layoutsFile.save(layouts)
  }

  private func prune() {
    guard layouts.count > Store.maximumRememberedDesks else { return }
    let ordered = layouts.values.sorted { $0.capturedAt > $1.capturedAt }
    layouts = Dictionary(
      uniqueKeysWithValues: ordered.prefix(Store.maximumRememberedDesks)
        .map { ($0.fingerprint, $0) }
    )
  }

  // MARK: - Receipts

  public var receipts: Receipts {
    receiptsStorage
  }

  public func recordLayoutWrite() {
    receiptsStorage.recordWrite()
    receiptsFile.save(receiptsStorage)
  }

  public func record(_ report: RestoreReport) {
    receiptsStorage.record(report)
    receiptsFile.save(receiptsStorage)
  }
}
