import Foundation

public enum InventoryAnalyzer {
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
}
