import Foundation

public enum PackageManager: String, Codable, CaseIterable, Sendable {
  case homebrewFormula = "homebrew-formula"
  case homebrewCask = "homebrew-cask"
  case cargo
  case npm
  case pipx
  case uv
  case manual
}

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
  case executable
  case installation
  case configuration
  case cache
  case log
  case state
  case session
  case credential
  case service
  case shellConfiguration = "shell-configuration"
  case unknown
}

public enum Confidence: String, Codable, CaseIterable, Sendable {
  case certain
  case high
  case medium
  case low
}

public struct Evidence: Codable, Hashable, Sendable {
  public let source: String
  public let detail: String

  public init(source: String, detail: String) {
    self.source = source
    self.detail = detail
  }
}

public struct Artifact: Codable, Hashable, Sendable {
  public let path: String
  public let kind: ArtifactKind
  public let confidence: Confidence
  public let sizeBytes: Int64?
  public let sensitive: Bool
  public let removable: Bool
  public let evidence: [Evidence]

  public init(
    path: String,
    kind: ArtifactKind,
    confidence: Confidence,
    sizeBytes: Int64? = nil,
    sensitive: Bool = false,
    removable: Bool = true,
    evidence: [Evidence]
  ) {
    self.path = path
    self.kind = kind
    self.confidence = confidence
    self.sizeBytes = sizeBytes
    self.sensitive = sensitive
    self.removable = removable
    self.evidence = evidence
  }
}

public struct PackageRecord: Codable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var displayName: String
  public var version: String?
  public var manager: PackageManager
  public var binaries: [String]
  public var artifacts: [Artifact]
  public var uninstallCommand: [String]?

  public init(
    id: String,
    name: String,
    displayName: String? = nil,
    version: String? = nil,
    manager: PackageManager,
    binaries: [String] = [],
    artifacts: [Artifact] = [],
    uninstallCommand: [String]? = nil
  ) {
    self.id = id
    self.name = name
    self.displayName = displayName ?? name
    self.version = version
    self.manager = manager
    self.binaries = binaries
    self.artifacts = artifacts
    self.uninstallCommand = uninstallCommand
  }
}

public struct ScanWarning: Codable, Hashable, Sendable {
  public let provider: String
  public let message: String

  public init(provider: String, message: String) {
    self.provider = provider
    self.message = message
  }
}

public struct Inventory: Codable, Sendable {
  public let schemaVersion: String
  public let generatedAt: Date
  public let host: String
  public var packages: [PackageRecord]
  public var warnings: [ScanWarning]

  public init(
    schemaVersion: String = "1.0",
    generatedAt: Date = Date(),
    host: String,
    packages: [PackageRecord],
    warnings: [ScanWarning] = []
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.host = host
    self.packages = packages
    self.warnings = warnings
  }
}

public enum RemovalMode: String, Codable, Sendable {
  case program
  case cache
  case full
}

public enum RemovalActionKind: String, Codable, Sendable {
  case runCommand = "run-command"
  case moveToTrash = "move-to-trash"
  case manualReview = "manual-review"
}

public struct RemovalAction: Codable, Hashable, Sendable {
  public let kind: RemovalActionKind
  public let description: String
  public let command: [String]?
  public let path: String?
  public let sensitive: Bool

  public init(
    kind: RemovalActionKind,
    description: String,
    command: [String]? = nil,
    path: String? = nil,
    sensitive: Bool = false
  ) {
    self.kind = kind
    self.description = description
    self.command = command
    self.path = path
    self.sensitive = sensitive
  }
}

public struct RemovalPlan: Codable, Sendable {
  public let schemaVersion: String
  public let packageID: String
  public let packageName: String
  public let mode: RemovalMode
  public let includeSensitive: Bool
  public let actions: [RemovalAction]
  public let estimatedBytes: Int64

  public init(
    schemaVersion: String = "1.0",
    packageID: String,
    packageName: String,
    mode: RemovalMode,
    includeSensitive: Bool,
    actions: [RemovalAction],
    estimatedBytes: Int64
  ) {
    self.schemaVersion = schemaVersion
    self.packageID = packageID
    self.packageName = packageName
    self.mode = mode
    self.includeSensitive = includeSensitive
    self.actions = actions
    self.estimatedBytes = estimatedBytes
  }
}

public struct ExecutionReport: Codable, Sendable {
  public let schemaVersion: String
  public let packageID: String
  public let executedAt: Date
  public let dryRun: Bool
  public let planned: [RemovalAction]
  public let completed: [RemovalAction]
  public let failed: [ActionFailure]

  public init(
    schemaVersion: String = "1.0",
    packageID: String,
    executedAt: Date = Date(),
    dryRun: Bool,
    planned: [RemovalAction],
    completed: [RemovalAction],
    failed: [ActionFailure]
  ) {
    self.schemaVersion = schemaVersion
    self.packageID = packageID
    self.executedAt = executedAt
    self.dryRun = dryRun
    self.planned = planned
    self.completed = completed
    self.failed = failed
  }
}

public struct ActionFailure: Codable, Sendable {
  public let action: RemovalAction
  public let error: String

  public init(action: RemovalAction, error: String) {
    self.action = action
    self.error = error
  }
}
