import Foundation

public struct CommandOutput: Sendable {
  public let status: Int32
  public let stdout: String
  public let stderr: String

  public init(status: Int32, stdout: String, stderr: String) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }
}

public protocol CommandRunning: Sendable {
  func run(_ executable: String, _ arguments: [String]) -> CommandOutput
}

public struct ProcessRunner: CommandRunning {
  public init() {}

  public func run(_ executable: String, _ arguments: [String]) -> CommandOutput {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
      process.waitUntilExit()
      let stdout =
        String(
          data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) ?? ""
      let stderr =
        String(
          data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) ?? ""
      return CommandOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    } catch {
      return CommandOutput(status: 127, stdout: "", stderr: error.localizedDescription)
    }
  }
}

public struct ScanContext: @unchecked Sendable {
  public let homeDirectory: String
  public let environment: [String: String]
  public let fileManager: FileManager
  public let runner: any CommandRunning

  public init(
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    runner: any CommandRunning = ProcessRunner()
  ) {
    self.homeDirectory = homeDirectory
    self.environment = environment
    self.fileManager = fileManager
    self.runner = runner
  }

  public func resolveExecutable(_ name: String, fallbacks: [String] = []) -> String? {
    let pathDirectories = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    for directory in pathDirectories + fallbacks {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      if fileManager.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}

public enum PathSafety {
  public static func expand(_ path: String, home: String) -> String {
    path
      .replacingOccurrences(of: "$HOME", with: home)
      .replacingOccurrences(of: "~/", with: home + "/")
  }

  public static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  public static func isSafeUserRemovalPath(_ path: String, home: String) -> Bool {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let protected = [
      "/", home, home + "/Library", home + "/Documents", home + "/Desktop",
      home + "/Downloads", home + "/Pictures", home + "/Movies", home + "/Music",
    ]
    guard !protected.contains(standardized) else { return false }
    return standardized.hasPrefix(home + "/")
  }
}

public enum FileSizer {
  public static func allocatedSize(
    at path: String,
    fileManager: FileManager = .default,
    limit: Int = 20_000
  ) -> Int64? {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    if !isDirectory.boolValue {
      let attributes = try? fileManager.attributesOfItem(atPath: path)
      return (attributes?[.size] as? NSNumber)?.int64Value
    }

    guard
      let enumerator = fileManager.enumerator(
        at: URL(fileURLWithPath: path),
        includingPropertiesForKeys: [
          .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return nil }

    var total: Int64 = 0
    var count = 0
    for case let url as URL in enumerator {
      count += 1
      if count > limit { return nil }
      guard
        let values = try? url.resourceValues(forKeys: [
          .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey,
        ])
      else { continue }
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        continue
      }
      total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
    return total
  }
}

public enum JSONOutput {
  public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting =
      pretty
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }
}
