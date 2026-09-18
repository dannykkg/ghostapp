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

  private func temporaryHome() throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostapp-tests-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
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
