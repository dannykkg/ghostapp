import Darwin
import Foundation

public struct RemovalPlanner {
  public init() {}

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
    } else {
      for artifact in package.artifacts where artifact.kind == .executable && artifact.removable {
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

      if artifact.kind == .shellConfiguration || !artifact.removable {
        actions.append(
          RemovalAction(
            kind: .manualReview,
            description: "Review \(artifact.kind.rawValue) manually",
            path: artifact.path,
            sensitive: artifact.sensitive
          ))
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

    return RemovalPlan(
      packageID: package.id,
      packageName: package.displayName,
      mode: mode,
      includeSensitive: includeSensitive,
      actions: actions,
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
}

public final class RemovalExecutor {
  private let context: ScanContext

  public init(context: ScanContext = ScanContext()) {
    self.context = context
  }

  public func execute(_ plan: RemovalPlan, dryRun: Bool) -> ExecutionReport {
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
    let trashRoot = makeTrashRoot(packageID: plan.packageID)

    for action in plan.actions {
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
        case .moveToTrash:
          guard let path = action.path else {
            throw RemovalError.invalidAction("Missing path")
          }
          try moveToTrash(path, root: trashRoot)
        case .manualReview:
          continue
        }
        completed.append(action)
      } catch {
        failed.append(ActionFailure(action: action, error: error.localizedDescription))
      }
    }

    return ExecutionReport(
      packageID: plan.packageID,
      dryRun: false,
      planned: plan.actions,
      completed: completed,
      failed: failed
    )
  }

  private func validateCommand(_ executable: String) throws {
    let allowedNames = Set(["brew", "cargo", "npm", "pipx", "uv", "launchctl"])
    let name = URL(fileURLWithPath: executable).lastPathComponent
    guard allowedNames.contains(name), context.fileManager.isExecutableFile(atPath: executable)
    else {
      throw RemovalError.unsafeCommand(executable)
    }
  }

  private func makeTrashRoot(packageID: String) -> String {
    let safeID = packageID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return context.homeDirectory
      + "/.Trash/ghostapp-\(String(safeID))-\(formatter.string(from: Date()))"
  }

  private func moveToTrash(_ path: String, root: String) throws {
    guard context.fileManager.fileExists(atPath: path) else { return }
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
  }
}

public enum RemovalError: LocalizedError {
  case unsafePath(String)
  case unsafeCommand(String)
  case invalidAction(String)
  case commandFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unsafePath(let path): "Refusing unsafe removal path: \(path)"
    case .unsafeCommand(let command): "Refusing unsafe command: \(command)"
    case .invalidAction(let message): "Invalid removal action: \(message)"
    case .commandFailed(let message):
      "Command failed: \(message.isEmpty ? "unknown error" : message)"
    }
  }
}
