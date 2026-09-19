import Foundation

public enum InventoryAnalyzer {
  public static func assessment(
    packages: [PackageRecord],
    warnings: [ScanWarning],
    findings: [InventoryFinding],
    duplicateProducts: [SoftwareProduct]
  ) -> InventoryAssessment {
    var items = warnings.map {
      AssessmentItem(
        level: .warning,
        title: "Scanner provider warning",
        detail: "\($0.provider): \($0.message)",
        confidence: .certain
      )
    }

    items += findings.map { finding in
      let level: AssessmentLevel
      let title: String
      switch finding.kind {
      case .brokenSymlink:
        level = .warning
        title = "Broken symbolic link"
      case .orphanLaunchService:
        level = .orphaned
        title = "Orphaned launch service"
      case .unclaimedLaunchService:
        level = .review
        title = "Unclassified launch service"
      case .stalePathEntry:
        if isDynamicSystemPath(finding.path) {
          level = .info
          title = "Dynamic system PATH entry is currently unavailable"
        } else {
          level = .warning
          title = "Stale PATH entry"
        }
      }
      return AssessmentItem(
        level: level,
        title: title,
        detail: finding.detail,
        path: finding.path,
        confidence: finding.confidence
      )
    }

    items += duplicateProducts.map { product in
      AssessmentItem(
        level: .warning,
        title: "Duplicate command installation",
        detail:
          "\(product.identity) has \(product.installations.count) installations; PATH selects \(product.activeBinary ?? "none").",
        path: product.activeBinary,
        confidence: .certain
      )
    }

    items.sort {
      let left = severity($0.level)
      let right = severity($1.level)
      if left != right { return left > right }
      return ($0.title, $0.path ?? "") < ($1.title, $1.path ?? "")
    }

    func count(_ level: AssessmentLevel) -> Int {
      items.lazy.filter { $0.level == level }.count
    }
    let duplicatePackageIDs = Set(
      duplicateProducts.flatMap(\.installations).map(\.packageID))
    let counts = AssessmentCounts(
      normal: packages.lazy.filter { !duplicatePackageIDs.contains($0.id) }.count,
      info: count(.info),
      review: count(.review),
      warning: count(.warning),
      orphaned: count(.orphaned),
      dangerous: count(.dangerous)
    )
    let status: InventoryStatus
    if counts.dangerous > 0 {
      status = .danger
    } else if counts.warning > 0 || counts.orphaned > 0 {
      status = .warning
    } else if counts.review > 0 {
      status = .needsReview
    } else {
      status = .healthy
    }
    let statistics = InventoryStatistics(
      packages: packages.count,
      directInstalls: packages.lazy.filter { $0.directInstall == true }.count,
      dependencies: packages.lazy.filter { $0.directInstall == false }.count,
      unclassified: packages.lazy.filter { $0.directInstall == nil }.count,
      duplicateCommands: duplicateProducts.count
    )
    return InventoryAssessment(
      status: status,
      statistics: statistics,
      counts: counts,
      items: items
    )
  }

  public static func duplicateProducts(
    packages: [PackageRecord],
    context: ScanContext
  ) -> [SoftwareProduct] {
    var grouped: [String: [(PackageRecord, String)]] = [:]
    for package in packages {
      for binary in package.binaries {
        let identity = URL(fileURLWithPath: binary).lastPathComponent.lowercased()
        grouped[identity, default: []].append((package, binary))
      }
    }

    return grouped.compactMap { identity, values -> SoftwareProduct? in
      var seenPaths = Set<String>()
      let unique = values.filter {
        seenPaths.insert(URL(fileURLWithPath: $0.1).standardizedFileURL.path).inserted
      }
      guard unique.count > 1 else { return nil }

      let active = activeBinary(named: identity, context: context)
      let installations = unique.map { package, binary in
        InstallationInstance(
          packageID: package.id,
          manager: package.manager,
          version: package.version,
          binary: binary,
          activeInPath: active == URL(fileURLWithPath: binary).standardizedFileURL.path
        )
      }
      .sorted {
        if $0.activeInPath != $1.activeInPath { return $0.activeInPath }
        return ($0.manager.rawValue, $0.binary) < ($1.manager.rawValue, $1.binary)
      }
      return SoftwareProduct(
        identity: identity,
        activeBinary: active,
        installations: installations
      )
    }
    .sorted { $0.identity < $1.identity }
  }

  private static func activeBinary(named name: String, context: ScanContext) -> String? {
    for directory in (context.environment["PATH"] ?? "").split(separator: ":").map(String.init) {
      let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      if context.fileManager.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path).standardizedFileURL.path
      }
    }
    return nil
  }

  private static func isDynamicSystemPath(_ path: String) -> Bool {
    path.hasPrefix("/var/run/com.apple.security.cryptexd/")
      || path.hasPrefix("/System/Cryptexes/")
      || path == "/pkg/env/global/bin"
  }

  private static func severity(_ level: AssessmentLevel) -> Int {
    switch level {
    case .normal: 0
    case .info: 1
    case .review: 2
    case .warning: 3
    case .orphaned: 4
    case .dangerous: 5
    }
  }
}
