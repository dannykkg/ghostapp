import Foundation

public final class TransactionStore {
  private let context: ScanContext
  private let root: String

  public init(context: ScanContext = ScanContext()) {
    self.context = context
    self.root = context.homeDirectory + "/.local/state/ghostapp/transactions"
  }

  public func save(_ manifest: TransactionManifest) throws {
    try context.fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest)
    try data.write(to: URL(fileURLWithPath: manifestPath(manifest.transactionID)), options: .atomic)
  }

  public func history() -> TransactionHistory {
    guard let entries = try? context.fileManager.contentsOfDirectory(atPath: root) else {
      return TransactionHistory(transactions: [])
    }
    let manifests = entries.compactMap { entry -> TransactionManifest? in
      guard entry.hasSuffix(".json"),
        let data = context.fileManager.contents(atPath: root + "/" + entry)
      else { return nil }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try? decoder.decode(TransactionManifest.self, from: data)
    }
    .sorted { $0.startedAt > $1.startedAt }
    return TransactionHistory(transactions: manifests)
  }

  public func load(_ transactionID: String) throws -> TransactionManifest {
    guard isSafeIdentifier(transactionID) else {
      throw TransactionError.invalidIdentifier(transactionID)
    }
    let path = manifestPath(transactionID)
    guard let data = context.fileManager.contents(atPath: path) else {
      throw TransactionError.notFound(transactionID)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TransactionManifest.self, from: data)
  }

  public func undo(_ transactionID: String, dryRun: Bool) -> UndoReport {
    let manifest: TransactionManifest
    do {
      manifest = try load(transactionID)
    } catch {
      return UndoReport(
        transactionID: transactionID,
        dryRun: dryRun,
        planned: [],
        restored: [],
        failed: [error.localizedDescription],
        note: "Package-manager commands are not automatically reversible."
      )
    }

    guard manifest.undoneAt == nil else {
      return UndoReport(
        transactionID: transactionID,
        dryRun: dryRun,
        planned: [],
        restored: [],
        failed: ["Transaction was already undone."],
        note: "Package-manager commands are not automatically reversible."
      )
    }

    let planned = manifest.moves.reversed()
    var preflightFailures: [String] = []
    for move in planned {
      if !isSafeTrashPath(move.trashPath) {
        preflightFailures.append("Unsafe Trash path: \(move.trashPath)")
      } else if !PathSafety.objectExists(at: move.trashPath) {
        preflightFailures.append("Trash item is missing: \(move.trashPath)")
      } else if !PathSafety.isSafeUserRemovalPath(move.originalPath, home: context.homeDirectory) {
        preflightFailures.append("Unsafe restore path: \(move.originalPath)")
      } else if PathSafety.objectExists(at: move.originalPath) {
        preflightFailures.append("Restore target already exists: \(move.originalPath)")
      }
    }
    if dryRun || !preflightFailures.isEmpty {
      return UndoReport(
        transactionID: transactionID,
        dryRun: dryRun,
        planned: Array(planned),
        restored: [],
        failed: preflightFailures,
        note: "Only files moved to Trash are restorable; package-manager commands are not reversed."
      )
    }

    var restored: [TransactionMove] = []
    var failures: [String] = []
    for move in planned {
      do {
        let parent = URL(fileURLWithPath: move.originalPath).deletingLastPathComponent().path
        try context.fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try context.fileManager.moveItem(atPath: move.trashPath, toPath: move.originalPath)
        restored.append(move)
      } catch {
        failures.append("\(move.originalPath): \(error.localizedDescription)")
        break
      }
    }

    if failures.isEmpty {
      let updated = TransactionManifest(
        transactionID: manifest.transactionID,
        packageID: manifest.packageID,
        planID: manifest.planID,
        planHash: manifest.planHash,
        startedAt: manifest.startedAt,
        finishedAt: manifest.finishedAt,
        moves: manifest.moves,
        completedCommands: manifest.completedCommands,
        failures: manifest.failures,
        undoneAt: Date()
      )
      try? save(updated)
    }

    return UndoReport(
      transactionID: transactionID,
      dryRun: false,
      planned: Array(planned),
      restored: restored,
      failed: failures,
      note: "Only files moved to Trash were restored; package-manager commands were not reversed."
    )
  }

  private func manifestPath(_ transactionID: String) -> String {
    root + "/" + transactionID + ".json"
  }

  private func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
  }

  private func isSafeTrashPath(_ path: String) -> Bool {
    let trash = PathSafety.canonical(context.homeDirectory + "/.Trash")
    let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
    let parent = PathSafety.canonical(
      URL(fileURLWithPath: lexical).deletingLastPathComponent().path)
    return parent.hasPrefix(trash + "/ghostapp-")
  }
}

public enum TransactionError: LocalizedError {
  case invalidIdentifier(String)
  case notFound(String)

  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier(let value): "Invalid transaction ID: \(value)"
    case .notFound(let value): "Transaction not found: \(value)"
    }
  }
}
