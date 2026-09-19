import Foundation

private struct ProviderResult {
  var packages: [PackageRecord] = []
  var warnings: [ScanWarning] = []
}

public final class InventoryScanner {
  private let context: ScanContext
  private let rules: RuleRegistry

  public init(context: ScanContext = ScanContext(), rules: RuleRegistry = .bundled()) {
    self.context = context
    self.rules = rules
  }

  public func scan() -> Inventory {
    var packages: [PackageRecord] = []
    var warnings: [ScanWarning] = []

    for result in [scanHomebrew(), scanRustup(), scanCargo(), scanNPM(), scanPipx(), scanUV()] {
      packages.append(contentsOf: result.packages)
      warnings.append(contentsOf: result.warnings)
    }

    let claimed = Set(packages.flatMap(\.binaries).map(PathSafety.canonical))
    let manual = scanManualBinaries(excluding: claimed)
    packages.append(contentsOf: manual.packages)
    warnings.append(contentsOf: manual.warnings)

    packages = packages.map(associateData)
    packages = associateLaunchServices(packages)
    packages = packages.map(associateShellConfiguration)
    packages = deduplicate(packages)
    let findings = scanFindings(packages: packages)
    let duplicateProducts = InventoryAnalyzer.duplicateProducts(
      packages: packages, context: context)

    let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    return Inventory(
      host: host,
      packages: packages.sorted {
        ($0.displayName.lowercased(), $0.manager.rawValue) < (
          $1.displayName.lowercased(), $1.manager.rawValue
        )
      },
      warnings: warnings,
      findings: findings,
      duplicateProducts: duplicateProducts
    )
  }

  private func scanHomebrew() -> ProviderResult {
    guard
      let brew = context.resolveTrustedExecutable(
        "brew",
        fallbacks: ["/opt/homebrew/bin", "/usr/local/bin"]
      )
    else { return ProviderResult() }

    let prefixOutput = context.runner.run(brew, ["--prefix"])
    guard prefixOutput.status == 0 else {
      return ProviderResult(warnings: [
        ScanWarning(provider: "homebrew", message: cleanError(prefixOutput.stderr))
      ])
    }
    let prefix = prefixOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestedOutput = context.runner.run(brew, ["leaves", "--installed-on-request"])
    let fallbackLeaves =
      requestedOutput.status == 0 ? requestedOutput : context.runner.run(brew, ["leaves"])
    let requestedFormulae = Set(
      fallbackLeaves.status == 0
        ? fallbackLeaves.stdout.split(whereSeparator: \.isNewline).map {
          $0.split(separator: " ").first.map(String.init) ?? ""
        }
        : [])
    var result = ProviderResult()
    result.packages += parseBrewList(
      context.runner.run(brew, ["list", "--formula", "--versions"]),
      manager: .homebrewFormula,
      brew: brew,
      prefix: prefix,
      requestedFormulae: requestedFormulae
    )
    result.packages += parseBrewList(
      context.runner.run(brew, ["list", "--cask", "--versions"]),
      manager: .homebrewCask,
      brew: brew,
      prefix: prefix,
      requestedFormulae: requestedFormulae
    )
    return result
  }

  private func parseBrewList(
    _ output: CommandOutput,
    manager: PackageManager,
    brew: String,
    prefix: String,
    requestedFormulae: Set<String>
  ) -> [PackageRecord] {
    guard output.status == 0 else { return [] }
    return output.stdout.split(whereSeparator: \.isNewline).compactMap { line in
      let parts = line.split(separator: " ").map(String.init)
      guard let name = parts.first else { return nil }
      let version = parts.dropFirst().first
      let base =
        manager == .homebrewFormula
        ? URL(fileURLWithPath: prefix).appendingPathComponent("Cellar/\(name)").path
        : URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/\(name)").path
      let binaries = binariesOwned(by: base, in: prefix)
      var artifacts: [Artifact] = []
      if context.fileManager.fileExists(atPath: base) {
        artifacts.append(
          Artifact(
            path: base,
            kind: .installation,
            confidence: .certain,
            sizeBytes: FileSizer.allocatedSize(at: base, fileManager: context.fileManager),
            removable: false,
            evidence: [Evidence(source: "homebrew", detail: "Installed package root")]
          ))
      }
      artifacts += binaries.map {
        Artifact(
          path: $0,
          kind: .executable,
          confidence: .certain,
          sizeBytes: FileSizer.allocatedSize(at: $0, fileManager: context.fileManager),
          removable: false,
          evidence: [Evidence(source: "homebrew", detail: "Managed binary link")]
        )
      }
      return PackageRecord(
        id: "\(manager.rawValue):\(name)",
        name: name,
        version: version,
        manager: manager,
        binaries: binaries,
        artifacts: artifacts,
        uninstallCommand: [brew, "uninstall"]
          + (manager == .homebrewCask ? ["--cask"] : ["--formula"]) + [name],
        directInstall: manager == .homebrewCask || requestedFormulae.contains(name)
      )
    }
  }

  private func scanRustup() -> ProviderResult {
    let binDirectory =
      (context.environment["CARGO_HOME"] ?? context.homeDirectory + "/.cargo") + "/bin"
    guard
      let rustup = context.resolveTrustedExecutable(
        "rustup", fallbacks: [binDirectory]),
      let rustupIdentity = FileIdentity.capture(rustup)
    else { return ProviderResult() }

    let entries = (try? context.fileManager.contentsOfDirectory(atPath: binDirectory)) ?? []
    let proxies = entries.compactMap { entry -> String? in
      let path = binDirectory + "/" + entry
      guard context.fileManager.isExecutableFile(atPath: path) else { return nil }
      let identity = FileIdentity.capture(path)
      let sameObject =
        identity?.device == rustupIdentity.device
        && identity?.inode == rustupIdentity.inode
      let sameResolvedTarget = PathSafety.canonical(path) == PathSafety.canonical(rustup)
      guard sameObject || sameResolvedTarget else { return nil }
      return path
    }
    .sorted()
    guard !proxies.isEmpty else { return ProviderResult() }

    let versionOutput = context.runner.run(rustup, ["--version"])
    let version = versionOutput.stdout.split(whereSeparator: \.isWhitespace).dropFirst().first.map(
      String.init)
    let rustupRoot = context.environment["RUSTUP_HOME"] ?? context.homeDirectory + "/.rustup"
    let cargoRoot = context.environment["CARGO_HOME"] ?? context.homeDirectory + "/.cargo"
    var artifacts = proxies.map { binaryArtifact($0, source: "rustup") }
    for path in [rustupRoot, cargoRoot] where context.fileManager.fileExists(atPath: path) {
      artifacts.append(
        Artifact(
          path: path,
          kind: .installation,
          confidence: .certain,
          sizeBytes: FileSizer.allocatedSize(at: path, fileManager: context.fileManager),
          removable: false,
          evidence: [Evidence(source: "rustup", detail: "Rust toolchain-managed root")]
        ))
    }
    return ProviderResult(packages: [
      PackageRecord(
        id: "rustup:toolchain",
        name: "rustup",
        displayName: "Rustup toolchain",
        version: version,
        manager: .rustup,
        binaries: proxies,
        artifacts: artifacts,
        uninstallCommand: [rustup, "self", "uninstall", "-y"],
        directInstall: true
      )
    ])
  }

  func binariesOwned(by packageRoot: String, in prefix: String) -> [String] {
    ["bin", "sbin"].flatMap { directory -> [String] in
      let binaryDirectory = URL(fileURLWithPath: prefix).appendingPathComponent(directory).path
      guard let entries = try? context.fileManager.contentsOfDirectory(atPath: binaryDirectory)
      else { return [] }
      return entries.compactMap { entry -> String? in
        let path = URL(fileURLWithPath: binaryDirectory).appendingPathComponent(entry).path
        let resolved = PathSafety.canonical(path)
        return resolved.hasPrefix(packageRoot + "/") ? path : nil
      }
    }.sorted()
  }

  private func scanCargo() -> ProviderResult {
    guard
      let cargo = context.resolveTrustedExecutable(
        "cargo",
        fallbacks: [context.homeDirectory + "/.cargo/bin"]
      )
    else { return ProviderResult() }
    let output = context.runner.run(cargo, ["install", "--list"])
    guard output.status == 0 else {
      return ProviderResult(warnings: [
        ScanWarning(provider: "cargo", message: cleanError(output.stderr))
      ])
    }

    var records: [PackageRecord] = []
    var currentName: String?
    var currentVersion: String?
    var binaries: [String] = []

    func makeRecord() -> PackageRecord? {
      guard let name = currentName else { return nil }
      let installRoot =
        context.environment["CARGO_INSTALL_ROOT"]
        ?? context.environment["CARGO_HOME"]
        ?? context.homeDirectory + "/.cargo"
      let paths = binaries.map { installRoot + "/bin/" + $0 }
        .filter { PathSafety.objectExists(at: $0) }
      return PackageRecord(
        id: "cargo:\(name)", name: name, version: currentVersion, manager: .cargo,
        binaries: paths,
        artifacts: paths.map { binaryArtifact($0, source: "cargo") },
        uninstallCommand: [cargo, "uninstall", name],
        directInstall: true
      )
    }

    for rawLine in output.stdout.components(separatedBy: .newlines) {
      if !rawLine.hasPrefix(" "), rawLine.hasSuffix(":") {
        if let record = makeRecord() { records.append(record) }
        let header = rawLine.dropLast().split(separator: " ")
        currentName = header.first.map(String.init)
        currentVersion = header.dropFirst().first.map {
          String($0).trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        }
        binaries = []
      } else if rawLine.hasPrefix("    ") {
        let binary = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !binary.isEmpty { binaries.append(binary) }
      }
    }
    if let record = makeRecord() { records.append(record) }
    return ProviderResult(packages: records)
  }

  private func scanNPM() -> ProviderResult {
    guard let npm = context.resolveTrustedExecutable("npm") else { return ProviderResult() }
    let list = context.runner.run(npm, ["list", "--global", "--depth=0", "--json"])
    guard list.status == 0 || !list.stdout.isEmpty,
      let data = list.stdout.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dependencies = root["dependencies"] as? [String: Any]
    else {
      return ProviderResult(warnings: [
        ScanWarning(provider: "npm", message: cleanError(list.stderr))
      ])
    }

    let prefixOutput = context.runner.run(npm, ["prefix", "--global"])
    let prefix = prefixOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard prefixOutput.status == 0, prefix.hasPrefix("/") else {
      return ProviderResult(warnings: [
        ScanWarning(provider: "npm", message: cleanError(prefixOutput.stderr))
      ])
    }
    let binDirectory = URL(fileURLWithPath: prefix).appendingPathComponent("bin").path
    let entries = (try? context.fileManager.contentsOfDirectory(atPath: binDirectory)) ?? []
    let records = dependencies.keys.sorted().map { name -> PackageRecord in
      let metadata = dependencies[name] as? [String: Any]
      let version = metadata?["version"] as? String
      let packageRoot = URL(fileURLWithPath: prefix).appendingPathComponent(
        "lib/node_modules/\(name)"
      ).path
      let binaries = entries.compactMap { entry -> String? in
        let path = URL(fileURLWithPath: binDirectory).appendingPathComponent(entry).path
        return PathSafety.canonical(path).hasPrefix(packageRoot + "/") ? path : nil
      }
      return PackageRecord(
        id: "npm:\(name)", name: name, version: version, manager: .npm,
        binaries: binaries,
        artifacts: binaries.map { binaryArtifact($0, source: "npm") },
        uninstallCommand: [npm, "uninstall", "--global", name],
        directInstall: true
      )
    }
    return ProviderResult(packages: records)
  }

  private func scanPipx() -> ProviderResult {
    guard let pipx = context.resolveTrustedExecutable("pipx") else { return ProviderResult() }
    let output = context.runner.run(pipx, ["list", "--json"])
    guard output.status == 0,
      let data = output.stdout.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let venvs = root["venvs"] as? [String: Any]
    else {
      return ProviderResult(warnings: [
        ScanWarning(provider: "pipx", message: cleanError(output.stderr))
      ])
    }
    let records = venvs.keys.sorted().map { name -> PackageRecord in
      let appDirectory = providerDirectory(
        executable: pipx,
        environmentKey: "PIPX_BIN_DIR",
        arguments: ["environment", "--value", "PIPX_BIN_DIR"],
        fallback: context.homeDirectory + "/.local/bin"
      )
      let entries = (try? context.fileManager.contentsOfDirectory(atPath: appDirectory)) ?? []
      let venvsDirectory = providerDirectory(
        executable: pipx,
        environmentKey: "PIPX_LOCAL_VENVS",
        arguments: ["environment", "--value", "PIPX_LOCAL_VENVS"],
        fallback: context.homeDirectory + "/.local/share/pipx/venvs"
      )
      let venv = venvs[name] as? [String: Any]
      let metadata = venv?["metadata"] as? [String: Any]
      let mainPackage = metadata?["main_package"] as? [String: Any]
      let declaredApps = mainPackage?["apps"] as? [String] ?? []
      let venvRoot = venvsDirectory + "/\(name)"
      let binaries = (declaredApps.isEmpty ? entries : declaredApps).compactMap {
        entry -> String? in
        let path = appDirectory + "/" + entry
        guard PathSafety.objectExists(at: path) else { return nil }
        if !declaredApps.isEmpty { return path }
        return PathSafety.canonical(path).hasPrefix(PathSafety.canonical(venvRoot) + "/")
          ? path : nil
      }
      return PackageRecord(
        id: "pipx:\(name)", name: name,
        version: mainPackage?["package_version"] as? String,
        manager: .pipx,
        binaries: binaries,
        artifacts: binaries.map { binaryArtifact($0, source: "pipx") },
        uninstallCommand: [pipx, "uninstall", name],
        directInstall: true
      )
    }
    return ProviderResult(packages: records)
  }

  private func scanUV() -> ProviderResult {
    guard let uv = context.resolveTrustedExecutable("uv") else { return ProviderResult() }
    let output = context.runner.run(uv, ["tool", "list"])
    guard output.status == 0 else {
      return ProviderResult(warnings: [
        ScanWarning(provider: "uv", message: cleanError(output.stderr))
      ])
    }
    let binDirectory = providerDirectory(
      executable: uv,
      environmentKey: "UV_TOOL_BIN_DIR",
      arguments: ["tool", "dir", "--bin"],
      fallback: context.homeDirectory + "/.local/bin"
    )
    var records: [PackageRecord] = []
    var currentName: String?
    var currentVersion: String?
    var apps: [String] = []

    func makeRecord() -> PackageRecord? {
      guard let name = currentName, !apps.isEmpty else { return nil }
      let binaries = apps.map { binDirectory + "/" + $0 }
        .filter { PathSafety.objectExists(at: $0) }
      return PackageRecord(
        id: "uv:\(name)", name: name, version: currentVersion, manager: .uv,
        binaries: binaries,
        artifacts: binaries.map { binaryArtifact($0, source: "uv") },
        uninstallCommand: [uv, "tool", "uninstall", name],
        directInstall: true
      )
    }

    for rawLine in output.stdout.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      if line.hasPrefix("-") {
        let app = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isEmpty { apps.append(app) }
        continue
      }
      if let record = makeRecord() { records.append(record) }
      let parts = line.split(separator: " ").map(String.init)
      currentName = parts.first
      currentVersion = parts.dropFirst().first
      apps = []
    }
    if let record = makeRecord() { records.append(record) }
    return ProviderResult(packages: records)
  }

  private func scanManualBinaries(excluding claimed: Set<String>) -> ProviderResult {
    let roots = [
      context.homeDirectory + "/.local/bin",
      context.homeDirectory + "/bin",
      context.homeDirectory + "/.grok/bin",
      context.homeDirectory + "/.cargo/bin",
      context.homeDirectory + "/go/bin",
    ]
    var grouped: [String: PackageRecord] = [:]
    for root in roots {
      guard let entries = try? context.fileManager.contentsOfDirectory(atPath: root) else {
        continue
      }
      for entry in entries.sorted() {
        let path = root + "/" + entry
        guard context.fileManager.isExecutableFile(atPath: path),
          !claimed.contains(PathSafety.canonical(path))
        else { continue }
        let rule = rules.matchingExecutable(path, home: context.homeDirectory)
        let name = rule?.id ?? entry
        let id =
          rule.map { "manual:\($0.id)" }
          ?? "manual:\(entry):\(root.replacingOccurrences(of: context.homeDirectory, with: "~"))"
        if grouped[id] == nil {
          grouped[id] = PackageRecord(
            id: id,
            name: name,
            displayName: rule?.displayName ?? entry,
            manager: .manual
          )
        }
        grouped[id]?.binaries.append(path)
        grouped[id]?.artifacts.append(
          binaryArtifact(path, source: "manual-path-scan", removable: true))
      }
    }
    return ProviderResult(packages: Array(grouped.values))
  }

  private func associateData(_ original: PackageRecord) -> PackageRecord {
    var package = original
    let rule = rules.matching(
      packageName: package.name,
      binaries: package.binaries,
      home: context.homeDirectory
    )
    if let rule {
      package.displayName = rule.displayName
      for dataPath in rule.dataPaths {
        let path = PathSafety.expand(dataPath.path, home: context.homeDirectory)
        guard context.fileManager.fileExists(atPath: path) else { continue }
        package.artifacts.append(
          Artifact(
            path: path,
            kind: dataPath.kind,
            confidence: .certain,
            sizeBytes: FileSizer.allocatedSize(at: path, fileManager: context.fileManager),
            sensitive: dataPath.sensitive,
            removable: PathSafety.isSafeUserRemovalPath(path, home: context.homeDirectory),
            evidence: [Evidence(source: "association-rule", detail: rule.id)]
          ))
      }
    }

    let normalized = genericName(package.name)
    if normalized.count >= 3 {
      let generic: [(String, ArtifactKind)] = [
        (context.homeDirectory + "/.\(normalized)", .state),
        (context.homeDirectory + "/.config/\(normalized)", .configuration),
        (context.homeDirectory + "/.cache/\(normalized)", .cache),
        (context.homeDirectory + "/.local/share/\(normalized)", .state),
        (context.homeDirectory + "/Library/Application Support/\(package.displayName)", .state),
        (context.homeDirectory + "/Library/Caches/\(normalized)", .cache),
        (context.homeDirectory + "/Library/Logs/\(normalized)", .log),
      ]
      for (path, kind) in generic where context.fileManager.fileExists(atPath: path) {
        if package.artifacts.contains(where: { $0.path == path }) { continue }
        package.artifacts.append(
          Artifact(
            path: path,
            kind: kind,
            confidence: .medium,
            sizeBytes: FileSizer.allocatedSize(at: path, fileManager: context.fileManager),
            sensitive: kind == .state,
            removable: PathSafety.isSafeUserRemovalPath(path, home: context.homeDirectory),
            evidence: [
              Evidence(source: "conventional-path", detail: "Exact normalized package-name match")
            ]
          ))
      }
    }
    return package
  }

  private func associateLaunchServices(_ originals: [PackageRecord]) -> [PackageRecord] {
    var packages = originals
    let directories = [
      context.homeDirectory + "/Library/LaunchAgents",
      "/Library/LaunchAgents",
      "/Library/LaunchDaemons",
    ]
    for directory in directories {
      guard let files = try? context.fileManager.contentsOfDirectory(atPath: directory) else {
        continue
      }
      for file in files where file.hasSuffix(".plist") {
        let path = directory + "/" + file
        guard let metadata = plistMetadata(at: path) else { continue }
        for index in packages.indices {
          let binaryMatch = packages[index].binaries.contains {
            PathSafety.canonical($0) == PathSafety.canonical(metadata.program)
          }
          let nameMatch = genericName(metadata.label).contains(genericName(packages[index].name))
          guard binaryMatch || (genericName(packages[index].name).count >= 4 && nameMatch) else {
            continue
          }
          let userOwned = path.hasPrefix(context.homeDirectory + "/")
          packages[index].artifacts.append(
            Artifact(
              path: path,
              kind: .service,
              confidence: binaryMatch ? .certain : .medium,
              sizeBytes: FileSizer.allocatedSize(at: path, fileManager: context.fileManager),
              removable: userOwned,
              evidence: [
                Evidence(source: "launchd", detail: "\(metadata.label) → \(metadata.program)")
              ]
            ))
        }
      }
    }
    return packages
  }

  private func associateShellConfiguration(_ original: PackageRecord) -> PackageRecord {
    var package = original
    let parents = Set(
      package.binaries.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
    let files = [".zshrc", ".zprofile", ".bash_profile", ".bashrc", ".profile"]
    for file in files {
      let path = context.homeDirectory + "/" + file
      guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      let matches = contents.components(separatedBy: .newlines).enumerated().compactMap {
        offset, line -> Int? in
        parents.contains(where: { line.contains($0) }) ? offset + 1 : nil
      }
      guard !matches.isEmpty else { continue }
      package.artifacts.append(
        Artifact(
          path: path,
          kind: .shellConfiguration,
          confidence: .high,
          sizeBytes: FileSizer.allocatedSize(at: path, fileManager: context.fileManager),
          sensitive: true,
          removable: false,
          evidence: [
            Evidence(
              source: "shell-profile",
              detail:
                "References binary directory on line(s) \(matches.map(String.init).joined(separator: ", "))"
            )
          ]
        ))
    }
    return package
  }

  private func deduplicate(_ originals: [PackageRecord]) -> [PackageRecord] {
    originals.map { original in
      var package = original
      package.binaries = Array(Set(package.binaries)).sorted()
      var seen = Set<String>()
      package.artifacts = package.artifacts.filter {
        seen.insert("\($0.kind.rawValue):\($0.path)").inserted
      }
      .sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) }
      return package
    }
  }

  private func scanFindings(packages: [PackageRecord]) -> [InventoryFinding] {
    var findings: [InventoryFinding] = []
    let manualRoots = [
      context.homeDirectory + "/.local/bin",
      context.homeDirectory + "/bin",
      context.homeDirectory + "/.grok/bin",
      context.homeDirectory + "/.cargo/bin",
      context.homeDirectory + "/go/bin",
    ]
    for root in manualRoots {
      let entries = (try? context.fileManager.contentsOfDirectory(atPath: root)) ?? []
      for entry in entries {
        let path = root + "/" + entry
        guard let identity = FileIdentity.capture(path), identity.symbolicLink,
          !context.fileManager.fileExists(atPath: path)
        else { continue }
        findings.append(
          InventoryFinding(
            kind: .brokenSymlink,
            path: path,
            confidence: .certain,
            detail: "Symbolic link target does not exist.",
            removable: PathSafety.isSafeUserRemovalPath(path, home: context.homeDirectory)
          ))
      }
    }

    var seenPathEntries = Set<String>()
    for rawEntry in (context.environment["PATH"] ?? "").split(separator: ":").map(String.init) {
      let path = PathSafety.expand(rawEntry, home: context.homeDirectory)
      guard path.hasPrefix("/"), seenPathEntries.insert(path).inserted,
        !context.fileManager.fileExists(atPath: path)
      else { continue }
      findings.append(
        InventoryFinding(
          kind: .stalePathEntry,
          path: path,
          confidence: .certain,
          detail: "PATH references a directory that does not exist."
        ))
    }

    let claimedServices = Set(
      packages.flatMap(\.artifacts).filter { $0.kind == .service }.map { $0.path })
    let launchDirectories = [
      context.homeDirectory + "/Library/LaunchAgents",
      "/Library/LaunchAgents",
      "/Library/LaunchDaemons",
    ]
    for directory in launchDirectories {
      let files = (try? context.fileManager.contentsOfDirectory(atPath: directory)) ?? []
      for file in files where file.hasSuffix(".plist") {
        let path = directory + "/" + file
        guard !claimedServices.contains(path), let metadata = plistMetadata(at: path) else {
          continue
        }
        let programMissing =
          metadata.program.hasPrefix("/")
          && !context.fileManager.fileExists(atPath: metadata.program)
        findings.append(
          InventoryFinding(
            kind: programMissing ? .orphanLaunchService : .unclaimedLaunchService,
            path: path,
            confidence: programMissing ? .high : .low,
            detail: programMissing
              ? "Launch service \(metadata.label) points to missing program \(metadata.program)."
              : "Launch service \(metadata.label) is not linked to a discovered package (program: \(metadata.program))."
          ))
      }
    }

    var seen = Set<String>()
    return findings.filter { seen.insert("\($0.kind.rawValue):\($0.path)").inserted }
      .sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) }
  }

  private func binaryArtifact(_ path: String, source: String, removable: Bool = false) -> Artifact {
    Artifact(
      path: path,
      kind: .executable,
      confidence: .certain,
      sizeBytes: FileSizer.allocatedSize(at: path, fileManager: context.fileManager),
      removable: removable,
      evidence: [Evidence(source: source, detail: "Package-owned executable")]
    )
  }

  private func plistMetadata(at path: String) -> (label: String, program: String)? {
    let plutil = "/usr/bin/plutil"
    guard
      TrustedExecutable.isAllowed(
        plutil,
        named: "plutil",
        home: context.homeDirectory,
        environment: context.environment,
        fileManager: context.fileManager
      ),
      context.fileManager.isReadableFile(atPath: path)
    else { return nil }
    let output = context.runner.run(plutil, ["-convert", "json", "-o", "-", path])
    guard output.status == 0,
      let data = output.stdout.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let label =
      object["Label"] as? String
      ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let arguments = object["ProgramArguments"] as? [String]
    let program = object["Program"] as? String ?? arguments?.first ?? ""
    guard !program.isEmpty else { return nil }
    return (label, program)
  }

  private func genericName(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "@", with: "-")
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: "-")
  }

  private func cleanError(_ value: String) -> String {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Provider returned no usable data" : cleaned
  }

  private func providerDirectory(
    executable: String,
    environmentKey: String,
    arguments: [String],
    fallback: String
  ) -> String {
    if let configured = context.environment[environmentKey], configured.hasPrefix("/") {
      return URL(fileURLWithPath: configured).standardizedFileURL.path
    }
    let output = context.runner.run(executable, arguments)
    let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if output.status == 0, value.hasPrefix("/") {
      return URL(fileURLWithPath: value).standardizedFileURL.path
    }
    return fallback
  }
}
