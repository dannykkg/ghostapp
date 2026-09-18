import Foundation
import Testing

@testable import GhostAppCore

private struct StubRunner: CommandRunning {
  let outputs: [String: CommandOutput]

  init(outputs: [String: CommandOutput] = [:]) {
    self.outputs = outputs
  }

  func run(_ executable: String, _ arguments: [String]) -> CommandOutput {
    outputs[([executable] + arguments).joined(separator: " ")]
      ?? CommandOutput(status: 127, stdout: "", stderr: "not available")
  }
}

@Suite("GhostApp core")
struct GhostAppCoreTests {
  @Test("Grok rule associates config, cache, and sensitive session data")
  func grokAssociation() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }

    let binary = home + "/.grok/bin/grok"
    try makeExecutable(at: binary)
    try write("theme = \"dark\"", to: home + "/.grok/config.toml")
    try write("token", to: home + "/.grok/auth.json")
    try write("conversation", to: home + "/.grok/sessions/one.json")
    try write("download", to: home + "/.grok/downloads/grok-macos")

    let rule = AssociationRule(
      id: "grok-build",
      displayName: "Grok Build",
      managerNames: ["grok-build"],
      executableNames: ["grok", "agent"],
      dataPaths: [
        .init(path: "$HOME/.grok/config.toml", kind: .configuration, sensitive: false),
        .init(path: "$HOME/.grok/auth.json", kind: .credential, sensitive: true),
        .init(path: "$HOME/.grok/sessions", kind: .session, sensitive: true),
        .init(path: "$HOME/.grok/downloads", kind: .cache, sensitive: false),
      ]
    )
    let context = ScanContext(
      homeDirectory: home,
      environment: ["PATH": home + "/.grok/bin"],
      runner: StubRunner()
    )
    let inventory = InventoryScanner(context: context, rules: RuleRegistry(rules: [rule])).scan()
    let package = try #require(inventory.packages.first { $0.id == "manual:grok-build" })

    #expect(package.displayName == "Grok Build")
    #expect(package.binaries == [binary])
    #expect(package.artifacts.contains { $0.kind == .configuration && !$0.sensitive })
    #expect(package.artifacts.contains { $0.kind == .credential && $0.sensitive })
    #expect(package.artifacts.contains { $0.kind == .session && $0.sensitive })
    #expect(package.artifacts.contains { $0.kind == .cache && !$0.sensitive })
  }

  @Test("Full plan protects sensitive artifacts unless explicitly included")
  func sensitivePlanning() {
    let package = PackageRecord(
      id: "manual:demo",
      name: "demo",
      manager: .manual,
      artifacts: [
        Artifact(
          path: "/tmp/home/.demo/cache", kind: .cache, confidence: .high, removable: true,
          evidence: []),
        Artifact(
          path: "/tmp/home/.demo/token", kind: .credential, confidence: .certain, sensitive: true,
          removable: true, evidence: []),
      ]
    )
    let planner = RemovalPlanner()
    let safe = planner.plan(package: package, mode: .full)
    let complete = planner.plan(package: package, mode: .full, includeSensitive: true)

    #expect(safe.actions.contains { $0.path == "/tmp/home/.demo/cache" })
    #expect(!safe.actions.contains { $0.path == "/tmp/home/.demo/token" })
    #expect(complete.actions.contains { $0.path == "/tmp/home/.demo/token" && $0.sensitive })
  }

  @Test("Executor moves associated data to a recoverable Trash folder")
  func trashExecution() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let cache = home + "/.demo/cache.db"
    try write("cache", to: cache)

    let action = RemovalAction(kind: .moveToTrash, description: "cache", path: cache)
    let plan = RemovalPlan(
      packageID: "manual:demo",
      packageName: "Demo",
      mode: .cache,
      includeSensitive: false,
      actions: [action],
      estimatedBytes: 5
    )
    let context = ScanContext(homeDirectory: home, environment: [:], runner: StubRunner())
    let report = RemovalExecutor(context: context).execute(plan, dryRun: false)

    #expect(report.failed.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: cache))
    let trash = try FileManager.default.contentsOfDirectory(atPath: home + "/.Trash")
    #expect(trash.count == 1)
  }

  @Test("Medium and low confidence artifacts require manual review")
  func confidenceGating() {
    let package = PackageRecord(
      id: "manual:demo",
      name: "demo",
      manager: .manual,
      artifacts: [
        Artifact(
          path: "/tmp/home/.config/demo", kind: .configuration, confidence: .medium,
          evidence: []),
        Artifact(
          path: "/tmp/home/.cache/demo", kind: .cache, confidence: .low,
          evidence: []),
        Artifact(
          path: "/tmp/home/.demo", kind: .state, confidence: .high,
          evidence: []),
      ]
    )

    let plan = RemovalPlanner().plan(package: package, mode: .full)

    #expect(
      plan.actions.contains { $0.path == "/tmp/home/.config/demo" && $0.kind == .manualReview })
    #expect(
      plan.actions.contains { $0.path == "/tmp/home/.cache/demo" && $0.kind == .manualReview })
    #expect(plan.actions.contains { $0.path == "/tmp/home/.demo" && $0.kind == .moveToTrash })
    #expect(
      !plan.actions.contains {
        ($0.path == "/tmp/home/.config/demo" || $0.path == "/tmp/home/.cache/demo")
          && $0.kind == .moveToTrash
      })
  }

  @Test("Parent symlink cannot escape the home directory")
  func parentSymlinkEscape() throws {
    let home = try temporaryHome()
    let outside = try temporaryHome()
    defer {
      try? FileManager.default.removeItem(atPath: home)
      try? FileManager.default.removeItem(atPath: outside)
    }
    let victim = outside + "/victim.db"
    try write("keep", to: victim)
    try FileManager.default.createSymbolicLink(
      atPath: home + "/.config", withDestinationPath: outside)

    let action = RemovalAction(
      kind: .moveToTrash,
      description: "escaped data",
      path: home + "/.config/victim.db"
    )
    let report = RemovalExecutor(context: ScanContext(homeDirectory: home, environment: [:]))
      .execute(removalPlan(actions: [action]), dryRun: false)

    #expect(report.completed.isEmpty)
    #expect(report.failed.count == 1)
    #expect(FileManager.default.fileExists(atPath: victim))
  }

  @Test("A final symlink is moved without touching its external target")
  func finalSymlinkIsMovedAsObject() throws {
    let home = try temporaryHome()
    let outside = try temporaryHome()
    defer {
      try? FileManager.default.removeItem(atPath: home)
      try? FileManager.default.removeItem(atPath: outside)
    }
    let target = outside + "/target.db"
    let link = home + "/.config/demo-link"
    try write("keep", to: target)
    try FileManager.default.createDirectory(
      atPath: home + "/.config", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

    let action = RemovalAction(kind: .moveToTrash, description: "link", path: link)
    let report = RemovalExecutor(context: ScanContext(homeDirectory: home, environment: [:]))
      .execute(removalPlan(actions: [action]), dryRun: false)

    #expect(report.failed.isEmpty)
    #expect(!PathSafety.objectExists(at: link))
    #expect(FileManager.default.fileExists(atPath: target))
  }

  @Test("Personal document directories are protected recursively")
  func protectedDirectories() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let document = home + "/Documents/report.txt"
    try write("keep", to: document)

    let action = RemovalAction(kind: .moveToTrash, description: "document", path: document)
    let report = RemovalExecutor(context: ScanContext(homeDirectory: home, environment: [:]))
      .execute(removalPlan(actions: [action]), dryRun: false)

    #expect(report.completed.isEmpty)
    #expect(report.failed.count == 1)
    #expect(FileManager.default.fileExists(atPath: document))
  }

  @Test("A package manager executable from an arbitrary PATH directory is rejected")
  func fakePackageManagerIsRejected() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let fakeBrew = home + "/project/bin/brew"
    try makeExecutable(at: fakeBrew)
    let action = RemovalAction(
      kind: .runCommand,
      description: "fake brew",
      command: [fakeBrew, "uninstall", "demo"]
    )
    let context = ScanContext(
      homeDirectory: home,
      environment: ["PATH": home + "/project/bin"],
      runner: StubRunner(outputs: [
        "\(fakeBrew) uninstall demo": CommandOutput(status: 0, stdout: "", stderr: "")
      ])
    )

    #expect(context.resolveTrustedExecutable("brew") == nil)
    let report = RemovalExecutor(context: context).execute(
      removalPlan(actions: [action]), dryRun: false)
    #expect(report.completed.isEmpty)
    #expect(report.failed.count == 1)
  }

  @Test("A trusted-looking executable symlink cannot point outside its manager root")
  func packageManagerSymlinkEscape() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let malicious = home + "/project/uv"
    let uv = home + "/.local/bin/uv"
    try makeExecutable(at: malicious)
    try FileManager.default.createDirectory(
      atPath: home + "/.local/bin", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: uv, withDestinationPath: malicious)

    #expect(
      !TrustedExecutable.isAllowed(
        uv,
        named: "uv",
        home: home,
        environment: [:]
      ))
  }

  @Test("Relative and parent-traversal removal paths are rejected")
  func pathTraversalIsRejected() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }

    #expect(!PathSafety.isSafeUserRemovalPath("relative/cache", home: home))
    #expect(!PathSafety.isSafeUserRemovalPath(home + "/.cache/../../outside", home: home))
  }

  @Test("Package uninstall failure stops dependent data cleanup")
  func commandFailureStopsCleanup() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let cache = home + "/.cache/demo"
    try write("keep", to: cache)
    let command = ["/bin/launchctl", "bootout", "gui/501", home + "/demo.plist"]
    let actions = [
      RemovalAction(kind: .runCommand, description: "unload", command: command),
      RemovalAction(kind: .moveToTrash, description: "cache", path: cache),
    ]
    let context = ScanContext(
      homeDirectory: home,
      environment: [:],
      runner: StubRunner(outputs: [
        command.joined(separator: " "): CommandOutput(
          status: 1, stdout: "", stderr: "service still running")
      ])
    )

    let report = RemovalExecutor(context: context).execute(
      removalPlan(actions: actions), dryRun: false)

    #expect(report.completed.isEmpty)
    #expect(report.failed.count == 1)
    #expect(FileManager.default.fileExists(atPath: cache))
  }

  @Test("A missing removal target is reported as a failure")
  func missingTargetIsNotCompleted() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let missing = home + "/.cache/missing"
    let action = RemovalAction(kind: .moveToTrash, description: "missing", path: missing)

    let report = RemovalExecutor(context: ScanContext(homeDirectory: home, environment: [:]))
      .execute(removalPlan(actions: [action]), dryRun: false)

    #expect(report.completed.isEmpty)
    #expect(report.failed.count == 1)
    #expect(report.failed[0].error.contains("no longer exists"))
  }

  @Test("Process runner times out and bounds captured output")
  func processRunnerLimits() {
    let timeoutRunner = ProcessRunner(timeout: 0.1)
    let started = Date()
    let timeout = timeoutRunner.run("/bin/sh", ["-c", "sleep 2"])
    #expect(timeout.status == 124)
    #expect(timeout.stderr.contains("timed out"))
    #expect(Date().timeIntervalSince(started) < 1.5)

    let outputRunner = ProcessRunner(timeout: 2, maxOutputBytes: 1_024)
    let output = outputRunner.run("/bin/sh", ["-c", "yes x | head -c 200000"])
    #expect(output.status == 0)
    #expect(output.stdout.contains("output truncated"))
    #expect(output.stdout.utf8.count < 2_000)
  }

  @Test("The bundled Grok rule does not claim a generic agent executable")
  func genericAgentDoesNotMatchGrok() {
    let rules = RuleRegistry.bundled()
    let home = "/Users/demo"
    #expect(rules.matchingExecutable(home + "/.local/bin/agent", home: home) == nil)
    #expect(rules.matchingExecutable(home + "/.grok/bin/agent", home: home)?.id == "grok-build")
    #expect(rules.matchingExecutable(home + "/.grok/bin/grok", home: home)?.id == "grok-build")
  }

  @Test("UV provider records declared executables and prevents manual duplicates")
  func uvProviderOwnership() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let uv = home + "/.local/bin/uv"
    let ruff = home + "/tools/bin/ruff"
    try makeExecutable(at: uv)
    try makeExecutable(at: ruff)
    let context = ScanContext(
      homeDirectory: home,
      environment: ["PATH": home + "/.local/bin", "UV_TOOL_BIN_DIR": home + "/tools/bin"],
      runner: StubRunner(outputs: [
        "\(uv) tool list": CommandOutput(
          status: 0, stdout: "ruff v0.12.0\n- ruff\n", stderr: "")
      ])
    )

    let inventory = InventoryScanner(context: context, rules: RuleRegistry(rules: [])).scan()
    let package = try #require(inventory.packages.first { $0.id == "uv:ruff" })
    #expect(package.version == "v0.12.0")
    #expect(package.binaries == [ruff])
    #expect(!inventory.packages.contains { $0.id.hasPrefix("manual:ruff:") })
  }

  @Test("pipx provider uses configured app directory and metadata")
  func pipxProviderPaths() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let pipx = home + "/.local/bin/pipx"
    let appDirectory = home + "/custom-apps"
    let black = appDirectory + "/black"
    try makeExecutable(at: pipx)
    try makeExecutable(at: black)
    let json =
      """
      {"venvs":{"black":{"metadata":{"main_package":{"package":"black","package_version":"25.1.0","apps":["black"]}}}}}
      """
    let context = ScanContext(
      homeDirectory: home,
      environment: [
        "PATH": home + "/.local/bin",
        "PIPX_BIN_DIR": appDirectory,
        "PIPX_LOCAL_VENVS": home + "/custom-venvs",
      ],
      runner: StubRunner(outputs: [
        "\(pipx) list --json": CommandOutput(status: 0, stdout: json, stderr: "")
      ])
    )

    let inventory = InventoryScanner(context: context, rules: RuleRegistry(rules: [])).scan()
    let package = try #require(inventory.packages.first { $0.id == "pipx:black" })
    #expect(package.version == "25.1.0")
    #expect(package.binaries == [black])
  }

  @Test("Cargo provider respects configured install root")
  func cargoInstallRoot() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let cargoHome = home + "/toolchain"
    let installRoot = home + "/cargo-apps"
    let cargo = cargoHome + "/bin/cargo"
    let demo = installRoot + "/bin/demo"
    try makeExecutable(at: cargo)
    try makeExecutable(at: demo)
    let context = ScanContext(
      homeDirectory: home,
      environment: [
        "PATH": cargoHome + "/bin",
        "CARGO_HOME": cargoHome,
        "CARGO_INSTALL_ROOT": installRoot,
      ],
      runner: StubRunner(outputs: [
        "\(cargo) install --list": CommandOutput(
          status: 0, stdout: "demo v1.2.3:\n    demo\n", stderr: "")
      ])
    )

    let inventory = InventoryScanner(context: context, rules: RuleRegistry(rules: [])).scan()
    let package = try #require(inventory.packages.first { $0.id == "cargo:demo" })
    #expect(package.binaries == [demo])
  }

  @Test("Homebrew ownership includes sbin links")
  func homebrewSbinOwnership() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let prefix = home + "/homebrew"
    let packageRoot = prefix + "/Cellar/demo"
    let target = packageRoot + "/1.0/sbin/demod"
    let link = prefix + "/sbin/demod"
    try makeExecutable(at: target)
    try FileManager.default.createDirectory(
      atPath: prefix + "/sbin", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    let scanner = InventoryScanner(
      context: ScanContext(homeDirectory: home, environment: [:], runner: StubRunner()),
      rules: RuleRegistry(rules: [])
    )

    #expect(scanner.binariesOwned(by: packageRoot, in: prefix) == [link])
  }

  @Test("npm provider records binaries from its reported global prefix")
  func npmGlobalPrefix() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let npmRoot = home + "/.nvm/versions/node/v24.0.0"
    let npm = npmRoot + "/bin/npm"
    let packageRoot = npmRoot + "/lib/node_modules/demo"
    let target = packageRoot + "/bin/demo.js"
    let link = npmRoot + "/bin/demo"
    try makeExecutable(at: npm)
    try makeExecutable(at: target)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    let context = ScanContext(
      homeDirectory: home,
      environment: ["PATH": npmRoot + "/bin"],
      runner: StubRunner(outputs: [
        "\(npm) list --global --depth=0 --json": CommandOutput(
          status: 0,
          stdout: "{\"dependencies\":{\"demo\":{\"version\":\"1.2.3\"}}}",
          stderr: ""
        ),
        "\(npm) prefix --global": CommandOutput(status: 0, stdout: npmRoot + "\n", stderr: ""),
      ])
    )

    let inventory = InventoryScanner(context: context, rules: RuleRegistry(rules: [])).scan()
    let package = try #require(inventory.packages.first { $0.id == "npm:demo" })
    #expect(package.version == "1.2.3")
    #expect(package.binaries == [link])
  }

  private func temporaryHome() throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostapp-tests-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func removalPlan(actions: [RemovalAction]) -> RemovalPlan {
    RemovalPlan(
      packageID: "manual:demo",
      packageName: "Demo",
      mode: .full,
      includeSensitive: false,
      actions: actions,
      estimatedBytes: 0
    )
  }

  private func makeExecutable(at path: String) throws {
    try write("#!/bin/sh\nexit 0\n", to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  }

  private func write(_ value: String, to path: String) throws {
    try FileManager.default.createDirectory(
      atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
      withIntermediateDirectories: true
    )
    try value.write(toFile: path, atomically: true, encoding: .utf8)
  }
}
