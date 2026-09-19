import Darwin
import Foundation

public struct RemovalPlanner {
  private let context: ScanContext

  public init(context: ScanContext = ScanContext()) {
    self.context = context
  }

  public func plan(
    package: PackageRecord,
    mode: RemovalMode,
    includeSensitive: Bool = false
  ) -> RemovalPlan {
    var actions: [RemovalAction] = []

    if let command = package.uninstallCommand {
      actions.append(
        RemovalAction(
          kind: .runCommand,
          description: "Uninstall \(package.displayName) with \(package.manager.rawValue)",
          command: command
        ))
      for binary in package.binaries {
        actions.append(
          RemovalAction(
            kind: .verifyPathAbsent,
            description: "Verify package executable is gone",
            path: binary
          ))
      }
    } else {
      for artifact in package.artifacts where artifact.kind == .executable && artifact.removable {
        guard isAutomaticallyRemovable(artifact) else {
          actions.append(manualReviewAction(for: artifact))
          continue
        }
        actions.append(
          RemovalAction(
            kind: .moveToTrash,
            description: "Move executable to Trash",
            path: artifact.path
          ))
      }
    }

    var estimatedBytes: Int64 = 0
    for artifact in package.artifacts {
      guard shouldInclude(artifact, mode: mode) else { continue }
      if artifact.sensitive && !includeSensitive { continue }
      if artifact.kind == .executable { continue }
      estimatedBytes += artifact.sizeBytes ?? 0

      if artifact.kind == .shellConfiguration || !artifact.removable
        || !isAutomaticallyRemovable(artifact)
      {
        actions.append(manualReviewAction(for: artifact))
        continue
      }

      if artifact.kind == .service {
        let domain = "gui/\(getuid())"
        actions.append(
          RemovalAction(
            kind: .runCommand,
            description: "Unload user launch service",
            command: ["/bin/launchctl", "bootout", domain, artifact.path]
          ))
      }
      actions.append(
        RemovalAction(
          kind: .moveToTrash,
          description: "Move \(artifact.kind.rawValue) to Trash",
          path: artifact.path,
          sensitive: artifact.sensitive
        ))
    }

    var seen = Set<String>()
    actions = actions.filter { action in
      let key =
        "\(action.kind.rawValue):\(action.path ?? action.command?.joined(separator: "\u{1f}") ?? "")"
      return seen.insert(key).inserted
    }

    let preconditionPaths = actions.compactMap { action -> String? in
      switch action.kind {
      case .runCommand: action.command?.first
      case .moveToTrash, .verifyPathAbsent: action.path
      case .manualReview: nil
      }
    }
    var seenPreconditions = Set<String>()
    let preconditions = preconditionPaths.compactMap { path -> PlanPrecondition? in
      guard seenPreconditions.insert(path).inserted else { return nil }
      return FileIdentity.capture(path)
    }

    return RemovalPlan(
      packageID: package.id,
      packageName: package.displayName,
      mode: mode,
      includeSensitive: includeSensitive,
      actions: actions,
      preconditions: preconditions,
      estimatedBytes: estimatedBytes
    )
  }

  private func shouldInclude(_ artifact: Artifact, mode: RemovalMode) -> Bool {
    switch mode {
    case .program:
      return false
    case .cache:
      return artifact.kind == .cache || artifact.kind == .log
    case .full:
      return artifact.kind != .executable
    }
  }

  private func isAutomaticallyRemovable(_ artifact: Artifact) -> Bool {
    artifact.confidence == .certain || artifact.confidence == .high
  }

  private func manualReviewAction(for artifact: Artifact) -> RemovalAction {
    RemovalAction(
      kind: .manualReview,
      description:
        "Review \(artifact.kind.rawValue) manually (\(artifact.confidence.rawValue) confidence)",
      path: artifact.path,
      sensitive: artifact.sensitive
    )
  }
}

public final class RemovalExecutor {
  private let context: ScanContext

  public init(context: ScanContext = ScanContext()) {
    self.context = context
  }

  public func execute(_ plan: RemovalPlan, dryRun: Bool) -> ExecutionReport {
    if !PlanIntegrity.isValid(plan) {
      let failure = planFailure("Plan hash does not match its contents")
      return ExecutionReport(
        packageID: plan.packageID,
        dryRun: dryRun,
        planned: plan.actions,
        completed: [],
        failed: [failure],
        skipped: plan.actions
      )
    }

    let stale = plan.preconditions.filter { !FileIdentity.matches($0) }
    if !stale.isEmpty {
      let paths = stale.map(\.path).joined(separator: ", ")
      let failure = planFailure("Plan is stale; filesystem identity changed: \(paths)")
      return ExecutionReport(
        packageID: plan.packageID,
        dryRun: dryRun,
        planned: plan.actions,
        completed: [],
        failed: [failure],
        skipped: plan.actions
      )
    }

    if dryRun {
      return ExecutionReport(
        packageID: plan.packageID,
        dryRun: true,
        planned: plan.actions,
        completed: [],
        failed: []
      )
    }

    var completed: [RemovalAction] = []
    var failed: [ActionFailure] = []
    var skipped: [RemovalAction] = []
    var moves: [TransactionMove] = []
    var completedCommands: [[String]] = []
    let startedAt = Date()
    let transactionID = UUID().uuidString.lowercased()
    let trashRoot = makeTrashRoot(packageID: plan.packageID, transactionID: transactionID)

    for (index, action) in plan.actions.enumerated() {
      do {
        switch action.kind {
        case .runCommand:
          guard let command = action.command, let executable = command.first else {
            throw RemovalError.invalidAction("Missing command")
          }
          try validateCommand(executable)
          let output = context.runner.run(executable, Array(command.dropFirst()))
          if output.status != 0 {
            throw RemovalError.commandFailed(
              output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
          }
          completedCommands.append(command)
        case .moveToTrash:
          guard let path = action.path else {
            throw RemovalError.invalidAction("Missing path")
          }
          moves.append(try moveToTrash(path, root: trashRoot))
        case .verifyPathAbsent:
          guard let path = action.path else {
            throw RemovalError.invalidAction("Missing verification path")
          }
          if PathSafety.objectExists(at: path) {
            throw RemovalError.verificationFailed(path)
          }
        case .manualReview:
          skipped.append(action)
          continue
        }
        completed.append(action)
      } catch {
        failed.append(ActionFailure(action: action, error: error.localizedDescription))
        if action.kind == .runCommand || action.kind == .verifyPathAbsent {
          skipped.append(contentsOf: plan.actions.dropFirst(index + 1))
          break
        }
      }
    }

    let manifest = TransactionManifest(
      transactionID: transactionID,
      packageID: plan.packageID,
      planID: plan.planID,
      planHash: plan.planHash,
      startedAt: startedAt,
      finishedAt: Date(),
      moves: moves,
      completedCommands: completedCommands,
      failures: failed.map(\.error)
    )
    do {
      try TransactionStore(context: context).save(manifest)
    } catch {
      failed.append(
        planFailure("Could not save transaction manifest: \(error.localizedDescription)"))
    }

    return ExecutionReport(
      packageID: plan.packageID,
      dryRun: false,
      planned: plan.actions,
      completed: completed,
      failed: failed,
      skipped: skipped,
      transactionID: transactionID
    )
  }

  private func validateCommand(_ executable: String) throws {
    guard
      TrustedExecutable.isAllowed(
        executable,
        home: context.homeDirectory,
        environment: context.environment,
        fileManager: context.fileManager
      )
    else {
      throw RemovalError.unsafeCommand(executable)
    }
  }

  private func makeTrashRoot(packageID: String, transactionID: String) -> String {
    let safeID = packageID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return context.homeDirectory
      + "/.Trash/ghostapp-\(String(safeID))-\(formatter.string(from: Date()))-\(transactionID)"
  }

  private func moveToTrash(_ path: String, root: String) throws -> TransactionMove {
    guard PathSafety.objectExists(at: path) else { throw RemovalError.pathNotFound(path) }
    guard PathSafety.isSafeUserRemovalPath(path, home: context.homeDirectory) else {
      throw RemovalError.unsafePath(path)
    }
    try context.fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    var destination = URL(fileURLWithPath: root).appendingPathComponent(
      URL(fileURLWithPath: path).lastPathComponent
    ).path
    var suffix = 1
    while context.fileManager.fileExists(atPath: destination) {
      destination =
        URL(fileURLWithPath: root)
        .appendingPathComponent("\(URL(fileURLWithPath: path).lastPathComponent)-\(suffix)").path
      suffix += 1
    }
    try context.fileManager.moveItem(atPath: path, toPath: destination)
    return TransactionMove(originalPath: path, trashPath: destination)
  }

  private func planFailure(_ message: String) -> ActionFailure {
    ActionFailure(
      action: RemovalAction(kind: .manualReview, description: "Plan validation"),
      error: message
    )
  }
}

public enum RemovalError: LocalizedError {
  case unsafePath(String)
  case unsafeCommand(String)
  case pathNotFound(String)
  case invalidAction(String)
  case commandFailed(String)
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unsafePath(let path): "Refusing unsafe removal path: \(path)"
    case .unsafeCommand(let command): "Refusing unsafe command: \(command)"
    case .pathNotFound(let path): "Removal target no longer exists: \(path)"
    case .invalidAction(let message): "Invalid removal action: \(message)"
    case .commandFailed(let message):
      "Command failed: \(message.isEmpty ? "unknown error" : message)"
    case .verificationFailed(let path):
      "Post-uninstall verification failed; path still exists: \(path)"
    }
  }
}
