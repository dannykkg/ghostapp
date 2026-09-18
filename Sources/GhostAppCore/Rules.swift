import Foundation

public struct AssociationRule: Codable, Sendable {
  public struct DataPath: Codable, Sendable {
    public let path: String
    public let kind: ArtifactKind
    public let sensitive: Bool
  }

  public let id: String
  public let displayName: String
  public let managerNames: [String]
  public let executableNames: [String]
  public let executablePaths: [String]?
  public let dataPaths: [DataPath]

  public init(
    id: String,
    displayName: String,
    managerNames: [String],
    executableNames: [String],
    executablePaths: [String] = [],
    dataPaths: [DataPath]
  ) {
    self.id = id
    self.displayName = displayName
    self.managerNames = managerNames
    self.executableNames = executableNames
    self.executablePaths = executablePaths
    self.dataPaths = dataPaths
  }
}

private struct RuleFile: Codable {
  let rules: [AssociationRule]
}

public struct RuleRegistry: Sendable {
  public let rules: [AssociationRule]

  public init(rules: [AssociationRule]) {
    self.rules = rules
  }

  public static func bundled() -> RuleRegistry {
    guard let url = Bundle.module.url(forResource: "rules", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(RuleFile.self, from: data)
    else {
      return RuleRegistry(rules: [])
    }
    return RuleRegistry(rules: decoded.rules)
  }

  public func matching(
    packageName: String,
    binaries: [String],
    home: String? = nil
  ) -> AssociationRule? {
    let normalizedName = normalize(packageName)
    let executableNames = Set(
      binaries.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
    return rules.first { rule in
      rule.managerNames.map(normalize).contains(normalizedName)
        || !Set(rule.executableNames.map { $0.lowercased() }).isDisjoint(with: executableNames)
        || binaries.contains { matchesScopedExecutable($0, rule: rule, home: home) }
    }
  }

  public func matchingExecutable(_ executable: String, home: String? = nil) -> AssociationRule? {
    let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
    return rules.first {
      $0.executableNames.map { $0.lowercased() }.contains(name)
        || matchesScopedExecutable(executable, rule: $0, home: home)
    }
  }

  public func normalize(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "@", with: "-")
  }

  private func matchesScopedExecutable(
    _ executable: String,
    rule: AssociationRule,
    home: String?
  ) -> Bool {
    guard let home else { return false }
    let candidate = URL(fileURLWithPath: executable).standardizedFileURL.path
    return (rule.executablePaths ?? []).contains {
      PathSafety.expand($0, home: home) == candidate
    }
  }
}
