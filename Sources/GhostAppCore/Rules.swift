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
  public let dataPaths: [DataPath]
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

  public func matching(packageName: String, binaries: [String]) -> AssociationRule? {
    let normalizedName = normalize(packageName)
    let executableNames = Set(
      binaries.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
    return rules.first { rule in
      rule.managerNames.map(normalize).contains(normalizedName)
        || !Set(rule.executableNames.map { $0.lowercased() }).isDisjoint(with: executableNames)
    }
  }

  public func matchingExecutable(_ executable: String) -> AssociationRule? {
    let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
    return rules.first { $0.executableNames.map { $0.lowercased() }.contains(name) }
  }

  public func normalize(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "@", with: "-")
  }
}
