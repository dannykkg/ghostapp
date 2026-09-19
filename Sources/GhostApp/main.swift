import Darwin
import Foundation
import GhostAppCore

@main
struct GhostAppCLI {
  static let version = "0.2.1"

  static func main() {
    do {
      try run(Array(CommandLine.arguments.dropFirst()))
    } catch let error as CLIError {
      fputs("ghostapp: \(error.message)\n", stderr)
      exit(error.code)
    } catch {
      fputs("ghostapp: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  static func run(_ arguments: [String]) throws {
    guard let command = arguments.first else {
      printHelp()
      return
    }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "help", "--help", "-h":
      printHelp()
    case "version", "--version", "-v":
      print("ghostapp \(version)")
    case "scan", "list":
      let options = try ScanOptions(rest)
      let inventory = InventoryScanner().scan()
      if options.common.json {
        try emit(inventory, options: options.common)
      } else {
        printScanSummary(inventory, showInfo: options.showInfo || options.showAll)
        if options.showAll { printInventoryDetails(inventory) }
      }
    case "duplicates":
      let options = try CommonOptions(rest)
      let products = InventoryScanner().scan().duplicateProducts
      if options.json {
        try emit(products, options: options)
      } else {
        printDuplicates(products)
      }
    case "inspect":
      let parsed = try QueryOptions(rest)
      let inventory = InventoryScanner().scan()
      let package = try resolve(parsed.query, in: inventory)
      if parsed.common.json {
        try emit(package, options: parsed.common)
      } else {
        printPackage(package)
      }
    case "plan":
      let parsed = try RemovalOptions(rest, allowsExecution: false)
      let inventory = InventoryScanner().scan()
      let package = try resolve(parsed.query, in: inventory)
      let plan = RemovalPlanner().plan(
        package: package,
        mode: parsed.mode,
        includeSensitive: parsed.includeSensitive
      )
      if parsed.common.json {
        try emit(plan, options: parsed.common)
      } else {
        printPlan(plan)
      }
    case "remove":
      let parsed = try RemovalOptions(rest, allowsExecution: true)
      if parsed.execute && !parsed.yes {
        throw CLIError("--execute requires --yes", code: 2)
      }
      let inventory = InventoryScanner().scan()
      let package = try resolve(parsed.query, in: inventory)
      let plan = RemovalPlanner().plan(
        package: package,
        mode: parsed.mode,
        includeSensitive: parsed.includeSensitive
      )
      let report = RemovalExecutor().execute(plan, dryRun: !parsed.execute)
      if parsed.common.json {
        try emit(report, options: parsed.common)
      } else if parsed.execute {
        printExecution(report)
      } else {
        printPlan(plan)
        print("\nDry run only. Add --execute --yes to apply this plan.")
      }
      if !report.failed.isEmpty { exit(10) }
    case "apply":
      let parsed = try ActionOptions(rest, noun: "plan file")
      if parsed.execute && !parsed.yes {
        throw CLIError("--execute requires --yes", code: 2)
      }
      let plan: RemovalPlan = try decodeJSONFile(parsed.value)
      let report = RemovalExecutor().execute(plan, dryRun: !parsed.execute)
      if parsed.common.json {
        try emit(report, options: parsed.common)
      } else if parsed.execute {
        printExecution(report)
      } else {
        printPlan(plan)
        print("\nFrozen plan validated. Dry run only; add --execute --yes to apply it.")
      }
      if !report.failed.isEmpty { exit(10) }
    case "history":
      let options = try CommonOptions(rest)
      let history = TransactionStore().history()
      if options.json {
        try emit(history, options: options)
      } else {
        printHistory(history)
      }
    case "undo":
      let parsed = try ActionOptions(rest, noun: "transaction ID")
      if parsed.execute && !parsed.yes {
        throw CLIError("--execute requires --yes", code: 2)
      }
      let report = TransactionStore().undo(parsed.value, dryRun: !parsed.execute)
      if parsed.common.json {
        try emit(report, options: parsed.common)
      } else {
        printUndo(report)
      }
      if !report.failed.isEmpty { exit(10) }
    case "doctor":
      let options = try CommonOptions(rest)
      let report = doctor()
      if options.json {
        try emit(report, options: options)
      } else {
        printDoctor(report)
      }
    default:
      throw CLIError("unknown command '\(command)'; run 'ghostapp help'", code: 2)
    }
  }
}

private struct CLIError: Error {
  let message: String
  let code: Int32

  init(_ message: String, code: Int32) {
    self.message = message
    self.code = code
  }
}

private struct CommonOptions {
  let json: Bool
  let compact: Bool
  let output: String?

  init(_ arguments: [String]) throws {
    var json = false
    var compact = false
    var output: String?
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--json": json = true
      case "--compact":
        compact = true
        json = true
      case "--output":
        index += 1
        guard index < arguments.count else { throw CLIError("--output requires a path", code: 2) }
        output = arguments[index]
        json = true
      default:
        throw CLIError("unexpected option '\(arguments[index])'", code: 2)
      }
      index += 1
    }
    self.json = json
    self.compact = compact
    self.output = output
  }
}

private struct ScanOptions {
  let showAll: Bool
  let showInfo: Bool
  let common: CommonOptions

  init(_ arguments: [String]) throws {
    var showAll = false
    var showInfo = false
    var commonArguments: [String] = []
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--all": showAll = true
      case "--show-info": showInfo = true
      case "--json", "--compact": commonArguments.append(arguments[index])
      case "--output":
        commonArguments.append(arguments[index])
        index += 1
        guard index < arguments.count else { throw CLIError("--output requires a path", code: 2) }
        commonArguments.append(arguments[index])
      default: throw CLIError("unexpected option '\(arguments[index])'", code: 2)
      }
      index += 1
    }
    self.showAll = showAll
    self.showInfo = showInfo
    self.common = try CommonOptions(commonArguments)
  }
}

private struct QueryOptions {
  let query: String
  let common: CommonOptions

  init(_ arguments: [String]) throws {
    guard let query = arguments.first, !query.hasPrefix("-") else {
      throw CLIError("a package name or ID is required", code: 2)
    }
    self.query = query
    self.common = try CommonOptions(Array(arguments.dropFirst()))
  }
}

private struct RemovalOptions {
  let query: String
  let mode: RemovalMode
  let includeSensitive: Bool
  let execute: Bool
  let yes: Bool
  let common: CommonOptions

  init(_ arguments: [String], allowsExecution: Bool) throws {
    guard let query = arguments.first, !query.hasPrefix("-") else {
      throw CLIError("a package name or ID is required", code: 2)
    }
    var mode: RemovalMode = .cache
    var includeSensitive = false
    var execute = false
    var yes = false
    var commonArguments: [String] = []
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--mode":
        index += 1
        guard index < arguments.count, let parsed = RemovalMode(rawValue: arguments[index]) else {
          throw CLIError("--mode must be program, cache, or full", code: 2)
        }
        mode = parsed
      case "--include-sensitive": includeSensitive = true
      case "--execute":
        guard allowsExecution else {
          throw CLIError("--execute is only valid with remove", code: 2)
        }
        execute = true
      case "--yes":
        guard allowsExecution else { throw CLIError("--yes is only valid with remove", code: 2) }
        yes = true
      case "--json", "--compact": commonArguments.append(arguments[index])
      case "--output":
        commonArguments.append(arguments[index])
        index += 1
        guard index < arguments.count else { throw CLIError("--output requires a path", code: 2) }
        commonArguments.append(arguments[index])
      default: throw CLIError("unexpected option '\(arguments[index])'", code: 2)
      }
      index += 1
    }
    self.query = query
    self.mode = mode
    self.includeSensitive = includeSensitive
    self.execute = execute
    self.yes = yes
    self.common = try CommonOptions(commonArguments)
  }
}

private struct ActionOptions {
  let value: String
  let execute: Bool
  let yes: Bool
  let common: CommonOptions

  init(_ arguments: [String], noun: String) throws {
    guard let value = arguments.first, !value.hasPrefix("-") else {
      throw CLIError("a \(noun) is required", code: 2)
    }
    var execute = false
    var yes = false
    var commonArguments: [String] = []
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--execute": execute = true
      case "--yes": yes = true
      case "--json", "--compact": commonArguments.append(arguments[index])
      case "--output":
        commonArguments.append(arguments[index])
        index += 1
        guard index < arguments.count else { throw CLIError("--output requires a path", code: 2) }
        commonArguments.append(arguments[index])
      default: throw CLIError("unexpected option '\(arguments[index])'", code: 2)
      }
      index += 1
    }
    self.value = value
    self.execute = execute
    self.yes = yes
    self.common = try CommonOptions(commonArguments)
  }
}

private struct DoctorCheck: Codable {
  let name: String
  let available: Bool
  let path: String?
}

private struct DoctorReport: Codable {
  let schemaVersion: String
  let platform: String
  let checks: [DoctorCheck]

  init(schemaVersion: String = "1.0", platform: String, checks: [DoctorCheck]) {
    self.schemaVersion = schemaVersion
    self.platform = platform
    self.checks = checks
  }
}

private func doctor() -> DoctorReport {
  let context = ScanContext()
  let names = ["brew", "rustup", "cargo", "npm", "pipx", "uv", "plutil"]
  let checks = names.map { name -> DoctorCheck in
    let fallback: [String]
    switch name {
    case "brew": fallback = ["/opt/homebrew/bin", "/usr/local/bin"]
    case "cargo", "rustup": fallback = [context.homeDirectory + "/.cargo/bin"]
    case "plutil": fallback = ["/usr/bin"]
    default: fallback = []
    }
    let path = context.resolveTrustedExecutable(name, fallbacks: fallback)
    return DoctorCheck(name: name, available: path != nil, path: path)
  }
  return DoctorReport(
    platform: ProcessInfo.processInfo.operatingSystemVersionString, checks: checks)
}

private func resolve(_ query: String, in inventory: Inventory) throws -> PackageRecord {
  let normalized = query.lowercased()
  let exact = inventory.packages.filter {
    $0.id.lowercased() == normalized || $0.name.lowercased() == normalized
      || $0.displayName.lowercased() == normalized
  }
  if exact.count == 1 { return exact[0] }

  let fuzzy = inventory.packages.filter { package in
    package.id.lowercased().contains(normalized) || package.name.lowercased().contains(normalized)
      || package.displayName.lowercased().contains(normalized)
      || package.binaries.contains {
        URL(fileURLWithPath: $0).lastPathComponent.lowercased() == normalized
      }
  }
  guard !fuzzy.isEmpty else { throw CLIError("no package matches '\(query)'", code: 3) }
  guard fuzzy.count == 1 else {
    throw CLIError(
      "ambiguous package '\(query)': \(fuzzy.map(\.id).joined(separator: ", "))", code: 4)
  }
  return fuzzy[0]
}

private func emit<T: Encodable>(_ value: T, options: CommonOptions) throws {
  let text = try JSONOutput.encode(value, pretty: !options.compact)
  if let output = options.output {
    try text.write(toFile: output, atomically: true, encoding: .utf8)
  } else {
    print(text)
  }
}

private func decodeJSONFile<T: Decodable>(_ path: String) throws -> T {
  do {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
  } catch {
    throw CLIError("cannot decode '\(path)': \(error.localizedDescription)", code: 2)
  }
}

private func printScanSummary(_ inventory: Inventory, showInfo: Bool) {
  let assessment = inventory.assessment
  let statistics = assessment.statistics
  let counts = assessment.counts
  print("GhostApp scan · \(statusLabel(assessment.status))")
  print(String(repeating: "-", count: 78))
  print(
    "✓ \(statistics.packages) packages recognized · \(statistics.directInstalls) direct · \(statistics.dependencies) dependencies · \(statistics.unclassified) unclassified"
  )
  if statistics.duplicateCommands == 0 {
    print("✓ No duplicate commands")
  } else {
    print("! \(statistics.duplicateCommands) duplicate command(s)")
  }
  if counts.warning == 0 && counts.orphaned == 0 && counts.dangerous == 0 {
    print("✓ No confirmed warnings, orphaned items, or dangerous findings")
  } else {
    if counts.dangerous > 0 { print("✗ \(counts.dangerous) dangerous finding(s)") }
    if counts.orphaned > 0 { print("! \(counts.orphaned) orphaned item(s)") }
    if counts.warning > 0 { print("! \(counts.warning) warning(s)") }
  }
  if counts.review > 0 { print("! \(counts.review) item(s) need review") }
  if counts.info > 0 {
    print(
      "i \(counts.info) informational item(s)\(showInfo ? "" : " · use --show-info to display")")
  }

  let visible = assessment.items.filter { showInfo || $0.level != .info }
  if visible.isEmpty {
    print("\nNo actionable anomalies detected.")
  } else {
    print("\nAssessment")
    for item in visible {
      print("  \(levelLabel(item.level))  \(item.title)")
      if let path = item.path { print("          \(path)") }
      print("          \(item.detail) [\(item.confidence.rawValue)]")
    }
  }
  print("\nUse 'ghostapp scan --all' for the complete package inventory.")
  print("Use 'ghostapp scan --compact' for deterministic JSON suitable for AI.")
}

private func printInventoryDetails(_ inventory: Inventory) {
  print("\nComplete package inventory")
  print(String(repeating: "-", count: 78))
  for package in inventory.packages {
    let version = package.version.map { " \($0)" } ?? ""
    let size = package.artifacts.compactMap(\.sizeBytes).reduce(0, +)
    print("\(package.displayName)\(version)")
    let ownership = package.directInstall.map { $0 ? "direct" : "dependency" } ?? "unclassified"
    print(
      "  ID: \(package.id) · \(package.manager.rawValue) · \(ownership) · \(formatBytes(size))"
    )
    print("  \(package.binaries.count) binaries · \(package.artifacts.count) artifacts")
  }
}

private func statusLabel(_ status: InventoryStatus) -> String {
  switch status {
  case .healthy: "HEALTHY"
  case .needsReview: "NEEDS REVIEW"
  case .warning: "WARNING"
  case .danger: "DANGER"
  }
}

private func levelLabel(_ level: AssessmentLevel) -> String {
  switch level {
  case .normal: "NORMAL   "
  case .info: "INFO     "
  case .review: "REVIEW   "
  case .warning: "WARNING  "
  case .orphaned: "ORPHANED "
  case .dangerous: "DANGEROUS"
  }
}

private func printPackage(_ package: PackageRecord) {
  print("\(package.displayName)\(package.version.map { " \($0)" } ?? "")")
  print("ID: \(package.id)")
  print("Manager: \(package.manager.rawValue)")
  if let direct = package.directInstall {
    print("Install class: \(direct ? "direct" : "dependency")")
  }
  if let command = package.uninstallCommand { print("Uninstall: \(shellQuote(command))") }
  print("\nArtifacts:")
  for artifact in package.artifacts {
    let flags = [artifact.confidence.rawValue, artifact.sensitive ? "sensitive" : nil]
      .compactMap { $0 }.joined(separator: ", ")
    print(
      "  [\(artifact.kind.rawValue)] \(artifact.path) · \(formatBytes(artifact.sizeBytes ?? 0)) · \(flags)"
    )
  }
}

private func printPlan(_ plan: RemovalPlan) {
  print("Removal plan for \(plan.packageName)")
  print("Plan: \(plan.planID) · sha256 \(plan.planHash)")
  print(
    "Mode: \(plan.mode.rawValue) · sensitive data: \(plan.includeSensitive ? "included" : "protected")"
  )
  print("Estimated associated data: \(formatBytes(plan.estimatedBytes))")
  for (index, action) in plan.actions.enumerated() {
    let target = action.path ?? action.command.map(shellQuote) ?? ""
    print("  \(index + 1). [\(action.kind.rawValue)] \(action.description)")
    if !target.isEmpty { print("     \(target)") }
  }
}

private func printExecution(_ report: ExecutionReport) {
  print(
    "Completed \(report.completed.count) action(s); skipped \(report.skipped.count); failed \(report.failed.count)."
  )
  if let transactionID = report.transactionID { print("Transaction: \(transactionID)") }
  for failure in report.failed {
    print("  FAILED: \(failure.action.description): \(failure.error)")
  }
}

private func printDuplicates(_ products: [SoftwareProduct]) {
  guard !products.isEmpty else {
    print("No duplicate commands found.")
    return
  }
  for product in products {
    print("\(product.identity) · \(product.installations.count) installations")
    for installation in product.installations {
      print(
        "  \(installation.activeInPath ? "ACTIVE" : "shadowed") · \(installation.manager.rawValue) · \(installation.binary)"
      )
    }
  }
}

private func printHistory(_ history: TransactionHistory) {
  guard !history.transactions.isEmpty else {
    print("No GhostApp transactions recorded.")
    return
  }
  for transaction in history.transactions {
    let state = transaction.undoneAt == nil ? "active" : "undone"
    print(
      "\(transaction.transactionID) · \(transaction.packageID) · \(state) · \(transaction.moves.count) Trash move(s)"
    )
  }
}

private func printUndo(_ report: UndoReport) {
  print(
    "Undo \(report.transactionID) · \(report.dryRun ? "dry run" : "executed") · restored \(report.restored.count)/\(report.planned.count)"
  )
  for failure in report.failed { print("  FAILED: \(failure)") }
  print(report.note)
}

private func printDoctor(_ report: DoctorReport) {
  print("GhostApp doctor · \(report.platform)")
  for check in report.checks {
    print("  \(check.available ? "✓" : "–") \(check.name)\(check.path.map { " · \($0)" } ?? "")")
  }
}

private func printHelp() {
  print(
    """
    ghostapp \(GhostAppCLI.version) — inventory and deeply uninstall non-.app macOS software

    USAGE
      ghostapp scan [--all] [--show-info] [--json|--compact] [--output FILE]
      ghostapp list [--all] [--show-info] [--json|--compact]
      ghostapp duplicates [--json|--compact]
      ghostapp inspect <name-or-id> [--json|--compact]
      ghostapp plan <name-or-id> [--mode program|cache|full] [--include-sensitive] [--json]
      ghostapp remove <name-or-id> [--mode program|cache|full] [--include-sensitive]
                      [--execute --yes] [--json]
      ghostapp apply <plan-file> [--execute --yes] [--json]
      ghostapp history [--json]
      ghostapp undo <transaction-id> [--execute --yes] [--json]
      ghostapp doctor [--json]
      ghostapp version

    SAFETY
      remove is a dry run unless both --execute and --yes are present.
      Sensitive credentials, sessions, and user state require --include-sensitive.
      Associated user files are moved to Trash, not permanently deleted.
      Frozen plans are hashed and checked against current file identities before execution.
      undo restores Trash moves only; package-manager uninstall commands are not reversible.

    AI / AUTOMATION
      Human output is the default. Add --compact for deterministic one-line JSON.
      Health classification is rule-based and does not require AI. Exit codes: 0 success,
      2 usage, 3 not found, 4 ambiguous, 10 execution failure.
    """)
}

private func formatBytes(_ bytes: Int64) -> String {
  ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func shellQuote(_ command: [String]) -> String {
  command.map { value in
    if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_/.:".contains($0) }) { return value }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }.joined(separator: " ")
}
