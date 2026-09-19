import Foundation

public enum PackageManager: String, Codable, CaseIterable, Sendable {
  case homebrewFormula = "homebrew-formula"
  case homebrewCask = "homebrew-cask"
  case cargo
  case npm
  case pipx
  case uv
  case rustup
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
  public var directInstall: Bool?

  public init(
    id: String,
    name: String,
    displayName: String? = nil,
    version: String? = nil,
    manager: PackageManager,
    binaries: [String] = [],
    artifacts: [Artifact] = [],
    uninstallCommand: [String]? = nil,
    directInstall: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.displayName = displayName ?? name
    self.version = version
    self.manager = manager
    self.binaries = binaries
    self.artifacts = artifacts
    self.uninstallCommand = uninstallCommand
    self.directInstall = directInstall
  }
}

public enum InventoryFindingKind: String, Codable, CaseIterable, Sendable {
  case brokenSymlink = "broken-symlink"
  case orphanLaunchService = "orphan-launch-service"
  case unclaimedLaunchService = "unclaimed-launch-service"
  case stalePathEntry = "stale-path-entry"
}

public struct InventoryFinding: Codable, Hashable, Sendable {
  public let kind: InventoryFindingKind
  public let path: String
  public let confidence: Confidence
  public let detail: String
  public let removable: Bool

  public init(
    kind: InventoryFindingKind,
    path: String,
    confidence: Confidence,
    detail: String,
    removable: Bool = false
  ) {
    self.kind = kind
    self.path = path
    self.confidence = confidence
    self.detail = detail
    self.removable = removable
  }
}

public struct InstallationInstance: Codable, Hashable, Sendable {
  public let packageID: String
  public let manager: PackageManager
  public let version: String?
  public let binary: String
  public let activeInPath: Bool

  public init(
    packageID: String,
    manager: PackageManager,
    version: String?,
    binary: String,
    activeInPath: Bool
  ) {
    self.packageID = packageID
    self.manager = manager
    self.version = version
    self.binary = binary
    self.activeInPath = activeInPath
  }
}

public struct SoftwareProduct: Codable, Hashable, Sendable {
  public let identity: String
  public let activeBinary: String?
  public let installations: [InstallationInstance]

  public init(
    identity: String,
    activeBinary: String?,
    installations: [InstallationInstance]
  ) {
    self.identity = identity
    self.activeBinary = activeBinary
    self.installations = installations
  }
}

public enum AssessmentLevel: String, Codable, CaseIterable, Sendable {
  case normal
  case info
  case review
  case warning
  case orphaned
  case dangerous
}

public enum InventoryStatus: String, Codable, Sendable {
  case healthy
  case needsReview = "needs-review"
  case warning
  case danger
}

public struct AssessmentItem: Codable, Hashable, Sendable {
  public let level: AssessmentLevel
  public let title: String
  public let summary: String
  public let detail: String
  public let path: String?
  public let packageID: String?
  public let confidence: Confidence

  public init(
    level: AssessmentLevel,
    title: String,
    summary: String,
    detail: String,
    path: String? = nil,
    packageID: String? = nil,
    confidence: Confidence
  ) {
    self.level = level
    self.title = title
    self.summary = summary
    self.detail = detail
    self.path = path
    self.packageID = packageID
    self.confidence = confidence
  }
}

public struct AssessmentCounts: Codable, Hashable, Sendable {
  public let normal: Int
  public let info: Int
  public let review: Int
  public let warning: Int
  public let orphaned: Int
  public let dangerous: Int

  public init(
    normal: Int = 0,
    info: Int = 0,
    review: Int = 0,
    warning: Int = 0,
    orphaned: Int = 0,
    dangerous: Int = 0
  ) {
    self.normal = normal
    self.info = info
    self.review = review
    self.warning = warning
    self.orphaned = orphaned
    self.dangerous = dangerous
  }
}

public struct InventoryStatistics: Codable, Hashable, Sendable {
  public let packages: Int
  public let directInstalls: Int
  public let dependencies: Int
  public let unclassified: Int
  public let duplicateCommands: Int

  public init(
    packages: Int,
    directInstalls: Int,
    dependencies: Int,
    unclassified: Int,
    duplicateCommands: Int
  ) {
    self.packages = packages
    self.directInstalls = directInstalls
    self.dependencies = dependencies
    self.unclassified = unclassified
    self.duplicateCommands = duplicateCommands
  }
}

public struct InventoryAssessment: Codable, Sendable {
  public let status: InventoryStatus
  public let statistics: InventoryStatistics
  public let counts: AssessmentCounts
  public let items: [AssessmentItem]

  public init(
    status: InventoryStatus,
    statistics: InventoryStatistics,
    counts: AssessmentCounts,
    items: [AssessmentItem]
  ) {
    self.status = status
    self.statistics = statistics
    self.counts = counts
    self.items = items
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
  public var findings: [InventoryFinding]
  public var duplicateProducts: [SoftwareProduct]
  public var assessment: InventoryAssessment

  public init(
    schemaVersion: String = "1.3",
    generatedAt: Date = Date(),
    host: String,
    packages: [PackageRecord],
    warnings: [ScanWarning] = [],
    findings: [InventoryFinding] = [],
    duplicateProducts: [SoftwareProduct] = [],
    assessment: InventoryAssessment? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.host = host
    self.packages = packages
    self.warnings = warnings
    self.findings = findings
    self.duplicateProducts = duplicateProducts
    self.assessment =
      assessment
      ?? InventoryAnalyzer.assessment(
        packages: packages,
        warnings: warnings,
        findings: findings,
        duplicateProducts: duplicateProducts
      )
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
  case verifyPathAbsent = "verify-path-absent"
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

public struct PlanPrecondition: Codable, Hashable, Sendable {
  public let path: String
  public let device: UInt64
  public let inode: UInt64
  public let symbolicLink: Bool

  public init(path: String, device: UInt64, inode: UInt64, symbolicLink: Bool) {
    self.path = path
    self.device = device
    self.inode = inode
    self.symbolicLink = symbolicLink
  }
}

public struct RemovalPlan: Codable, Sendable {
  public let schemaVersion: String
  public let planID: String
  public let planHash: String
  public let generatedAt: Date
  public let packageID: String
  public let packageName: String
  public let mode: RemovalMode
  public let includeSensitive: Bool
  public let actions: [RemovalAction]
  public let preconditions: [PlanPrecondition]
  public let estimatedBytes: Int64

  public init(
    schemaVersion: String = "1.1",
    planID: String = UUID().uuidString.lowercased(),
    generatedAt: Date = Date(),
    packageID: String,
    packageName: String,
    mode: RemovalMode,
    includeSensitive: Bool,
    actions: [RemovalAction],
    preconditions: [PlanPrecondition] = [],
    estimatedBytes: Int64,
    planHash: String? = nil
  ) {
    let normalizedGeneratedAt = Date(
      timeIntervalSince1970: floor(generatedAt.timeIntervalSince1970))
    self.schemaVersion = schemaVersion
    self.planID = planID
    self.generatedAt = normalizedGeneratedAt
    self.packageID = packageID
    self.packageName = packageName
    self.mode = mode
    self.includeSensitive = includeSensitive
    self.actions = actions
    self.preconditions = preconditions
    self.estimatedBytes = estimatedBytes
    self.planHash =
      planHash
      ?? PlanIntegrity.hash(
        schemaVersion: schemaVersion,
        planID: planID,
        generatedAt: normalizedGeneratedAt,
        packageID: packageID,
        packageName: packageName,
        mode: mode,
        includeSensitive: includeSensitive,
        actions: actions,
        preconditions: preconditions,
        estimatedBytes: estimatedBytes
      )
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
  public let skipped: [RemovalAction]
  public let transactionID: String?

  public init(
    schemaVersion: String = "1.1",
    packageID: String,
    executedAt: Date = Date(),
    dryRun: Bool,
    planned: [RemovalAction],
    completed: [RemovalAction],
    failed: [ActionFailure],
    skipped: [RemovalAction] = [],
    transactionID: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.packageID = packageID
    self.executedAt = executedAt
    self.dryRun = dryRun
    self.planned = planned
    self.completed = completed
    self.failed = failed
    self.skipped = skipped
    self.transactionID = transactionID
  }
}

public struct TransactionMove: Codable, Hashable, Sendable {
  public let originalPath: String
  public let trashPath: String

  public init(originalPath: String, trashPath: String) {
    self.originalPath = originalPath
    self.trashPath = trashPath
  }
}

public struct TransactionManifest: Codable, Sendable {
  public let schemaVersion: String
  public let transactionID: String
  public let packageID: String
  public let planID: String
  public let planHash: String
  public let startedAt: Date
  public let finishedAt: Date
  public let moves: [TransactionMove]
  public let completedCommands: [[String]]
  public let failures: [String]
  public let undoneAt: Date?

  public init(
    schemaVersion: String = "1.0",
    transactionID: String,
    packageID: String,
    planID: String,
    planHash: String,
    startedAt: Date,
    finishedAt: Date,
    moves: [TransactionMove],
    completedCommands: [[String]],
    failures: [String],
    undoneAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.transactionID = transactionID
    self.packageID = packageID
    self.planID = planID
    self.planHash = planHash
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.moves = moves
    self.completedCommands = completedCommands
    self.failures = failures
    self.undoneAt = undoneAt
  }
}

public struct TransactionHistory: Codable, Sendable {
  public let schemaVersion: String
  public let transactions: [TransactionManifest]

  public init(schemaVersion: String = "1.0", transactions: [TransactionManifest]) {
    self.schemaVersion = schemaVersion
    self.transactions = transactions
  }
}

public struct UndoReport: Codable, Sendable {
  public let schemaVersion: String
  public let transactionID: String
  public let dryRun: Bool
  public let planned: [TransactionMove]
  public let restored: [TransactionMove]
  public let failed: [String]
  public let note: String

  public init(
    schemaVersion: String = "1.0",
    transactionID: String,
    dryRun: Bool,
    planned: [TransactionMove],
    restored: [TransactionMove],
    failed: [String],
    note: String
  ) {
    self.schemaVersion = schemaVersion
    self.transactionID = transactionID
    self.dryRun = dryRun
    self.planned = planned
    self.restored = restored
    self.failed = failed
    self.note = note
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
