import Darwin
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
  private let timeout: TimeInterval
  private let maxOutputBytes: Int

  public init(timeout: TimeInterval = 120, maxOutputBytes: Int = 1_048_576) {
    self.timeout = max(0.1, timeout)
    self.maxOutputBytes = max(1_024, maxOutputBytes)
  }

  public func run(_ executable: String, _ arguments: [String]) -> CommandOutput {
    let fileManager = FileManager.default
    let outputDirectory = fileManager.temporaryDirectory.appendingPathComponent(
      "ghostapp-process-\(UUID().uuidString)", isDirectory: true)
    let stdoutURL = outputDirectory.appendingPathComponent("stdout")
    let stderrURL = outputDirectory.appendingPathComponent("stderr")

    do {
      try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
      guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
      else {
        throw CocoaError(.fileWriteUnknown)
      }
    } catch {
      return CommandOutput(status: 127, stdout: "", stderr: error.localizedDescription)
    }
    defer { try? fileManager.removeItem(at: outputDirectory) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    do {
      let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
      let stderrHandle = try FileHandle(forWritingTo: stderrURL)
      process.standardOutput = stdoutHandle
      process.standardError = stderrHandle
      try process.run()

      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
      }

      let timedOut = process.isRunning
      if timedOut {
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < graceDeadline {
          Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
        }
      }
      process.waitUntilExit()
      try? stdoutHandle.close()
      try? stderrHandle.close()

      let stdout = readOutput(at: stdoutURL, fileManager: fileManager)
      var stderr = readOutput(at: stderrURL, fileManager: fileManager)
      if timedOut {
        if !stderr.isEmpty && !stderr.hasSuffix("\n") { stderr += "\n" }
        stderr += "Command timed out after \(formatTimeout(timeout)) seconds"
      }
      return CommandOutput(
        status: timedOut ? 124 : process.terminationStatus,
        stdout: stdout,
        stderr: stderr
      )
    } catch {
      return CommandOutput(status: 127, stdout: "", stderr: error.localizedDescription)
    }
  }

  private func readOutput(at url: URL, fileManager: FileManager) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxOutputBytes)) ?? Data()
    var text = String(decoding: data, as: UTF8.self)
    let size =
      ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue
      ?? data.count
    if size > maxOutputBytes {
      if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
      text += "[output truncated at \(maxOutputBytes) bytes]"
    }
    return text
  }

  private func formatTimeout(_ value: TimeInterval) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
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
    resolveTrustedExecutable(name, fallbacks: fallbacks)
  }

  public func resolveTrustedExecutable(_ name: String, fallbacks: [String] = []) -> String? {
    let pathDirectories = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    for directory in pathDirectories + fallbacks {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      if TrustedExecutable.isAllowed(
        candidate,
        named: name,
        home: homeDirectory,
        environment: environment,
        fileManager: fileManager
      ) {
        return candidate
      }
    }
    return nil
  }
}

public enum TrustedExecutable {
  private static let supportedNames = Set([
    "brew", "cargo", "npm", "pipx", "uv", "launchctl", "plutil",
  ])

  public static func isAllowed(
    _ path: String,
    named expectedName: String? = nil,
    home: String,
    environment: [String: String] = [:],
    fileManager: FileManager = .default
  ) -> Bool {
    guard path.hasPrefix("/") else { return false }
    let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
    guard lexical == path, fileManager.isExecutableFile(atPath: lexical) else { return false }

    let name = URL(fileURLWithPath: lexical).lastPathComponent
    guard supportedNames.contains(name), expectedName == nil || name == expectedName else {
      return false
    }

    if name == "launchctl" {
      return lexical == "/bin/launchctl" && PathSafety.canonical(lexical) == "/bin/launchctl"
    }
    if name == "plutil" {
      return lexical == "/usr/bin/plutil" && PathSafety.canonical(lexical) == "/usr/bin/plutil"
    }

    let systemLocations = [
      ("/opt/homebrew/bin/\(name)", "/opt/homebrew"),
      ("/usr/local/bin/\(name)", "/usr/local"),
      ("/usr/bin/\(name)", "/usr/bin"),
    ]
    for (location, root) in systemLocations where lexical == location {
      return isWithin(PathSafety.canonical(lexical), root: PathSafety.canonical(root))
    }

    let standardizedHome = URL(fileURLWithPath: home).standardizedFileURL.path
    let configuredDirectories = configuredUserDirectories(
      for: name, home: standardizedHome, environment: environment)
    for directory in configuredDirectories {
      let standardizedDirectory = URL(fileURLWithPath: directory).standardizedFileURL.path
      guard lexical == standardizedDirectory + "/" + name else { continue }
      let canonicalDirectory = PathSafety.canonical(standardizedDirectory)
      return isWithin(PathSafety.canonical(lexical), root: canonicalDirectory)
    }

    if name == "pipx" {
      let pythonRoot = standardizedHome + "/Library/Python"
      return isWithin(lexical, root: pythonRoot) && lexical.hasSuffix("/bin/pipx")
        && isWithin(PathSafety.canonical(lexical), root: PathSafety.canonical(pythonRoot))
    }

    guard name == "npm" else { return false }
    let npmRoots = [
      standardizedHome + "/.nvm",
      standardizedHome + "/.fnm",
      standardizedHome + "/.volta",
      standardizedHome + "/.asdf",
      standardizedHome + "/.local/share/fnm",
      standardizedHome + "/.local/share/mise",
      standardizedHome + "/Library/Application Support/fnm",
      standardizedHome + "/Library/Application Support/mise",
    ]
    return npmRoots.contains { root in
      isWithin(lexical, root: root)
        && isWithin(PathSafety.canonical(lexical), root: PathSafety.canonical(root))
    }
  }

  private static func configuredUserDirectories(
    for name: String,
    home: String,
    environment: [String: String]
  ) -> [String] {
    var directories: [String] = []
    switch name {
    case "cargo":
      directories.append((environment["CARGO_HOME"] ?? home + "/.cargo") + "/bin")
    case "pipx":
      directories.append(home + "/.local/bin")
      if let pipxBin = environment["PIPX_BIN_DIR"] { directories.append(pipxBin) }
    case "uv":
      directories.append(environment["UV_INSTALL_DIR"] ?? home + "/.local/bin")
      directories.append(home + "/.cargo/bin")
    case "npm":
      if let nvmBin = environment["NVM_BIN"] { directories.append(nvmBin) }
      if let voltaHome = environment["VOLTA_HOME"] { directories.append(voltaHome + "/bin") }
    default:
      break
    }
    return directories
  }

  private static func isWithin(_ candidate: String, root: String) -> Bool {
    candidate == root || candidate.hasPrefix(root + "/")
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
    guard path.hasPrefix("/") else { return false }
    let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
    let lexicalHome = URL(fileURLWithPath: home).standardizedFileURL.path
    guard lexical != lexicalHome, lexical.hasPrefix(lexicalHome + "/") else { return false }

    let url = URL(fileURLWithPath: lexical)
    let parent = url.deletingLastPathComponent().path
    let canonicalHome = canonical(lexicalHome)
    let canonicalParent = canonical(parent)
    guard canonicalParent == canonicalHome || canonicalParent.hasPrefix(canonicalHome + "/") else {
      return false
    }

    let objectPath: String
    if isSymbolicLink(at: lexical) {
      objectPath =
        URL(fileURLWithPath: canonicalParent).appendingPathComponent(url.lastPathComponent).path
    } else {
      objectPath = canonical(lexical)
    }
    guard objectPath != canonicalHome, objectPath.hasPrefix(canonicalHome + "/") else {
      return false
    }

    let protectedNames = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"]
    let protectedLexicalRoots = protectedNames.map { lexicalHome + "/" + $0 }
    guard
      !protectedLexicalRoots.contains(where: { lexical == $0 || lexical.hasPrefix($0 + "/") })
    else { return false }
    let protectedCanonicalRoots = protectedNames.map { canonicalHome + "/" + $0 }
    guard
      !protectedCanonicalRoots.contains(where: {
        objectPath == $0 || objectPath.hasPrefix($0 + "/")
      })
    else { return false }
    return objectPath != canonicalHome + "/Library"
  }

  public static func objectExists(at path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  public static func isSymbolicLink(at path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFLNK
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
