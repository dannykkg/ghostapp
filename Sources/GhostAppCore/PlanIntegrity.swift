import CryptoKit
import Darwin
import Foundation

private struct PlanHashPayload: Encodable {
  let schemaVersion: String
  let planID: String
  let generatedAt: Date
  let packageID: String
  let packageName: String
  let mode: RemovalMode
  let includeSensitive: Bool
  let actions: [RemovalAction]
  let preconditions: [PlanPrecondition]
  let estimatedBytes: Int64
}

public enum PlanIntegrity {
  public static func hash(
    schemaVersion: String,
    planID: String,
    generatedAt: Date,
    packageID: String,
    packageName: String,
    mode: RemovalMode,
    includeSensitive: Bool,
    actions: [RemovalAction],
    preconditions: [PlanPrecondition],
    estimatedBytes: Int64
  ) -> String {
    let payload = PlanHashPayload(
      schemaVersion: schemaVersion,
      planID: planID,
      generatedAt: generatedAt,
      packageID: packageID,
      packageName: packageName,
      mode: mode,
      includeSensitive: includeSensitive,
      actions: actions,
      preconditions: preconditions,
      estimatedBytes: estimatedBytes
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(payload)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func hash(_ plan: RemovalPlan) -> String {
    hash(
      schemaVersion: plan.schemaVersion,
      planID: plan.planID,
      generatedAt: plan.generatedAt,
      packageID: plan.packageID,
      packageName: plan.packageName,
      mode: plan.mode,
      includeSensitive: plan.includeSensitive,
      actions: plan.actions,
      preconditions: plan.preconditions,
      estimatedBytes: plan.estimatedBytes
    )
  }

  public static func isValid(_ plan: RemovalPlan) -> Bool {
    plan.planHash == hash(plan)
  }
}

public enum FileIdentity {
  public static func capture(_ path: String) -> PlanPrecondition? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return PlanPrecondition(
      path: path,
      device: UInt64(info.st_dev),
      inode: UInt64(info.st_ino),
      symbolicLink: info.st_mode & S_IFMT == S_IFLNK
    )
  }

  public static func matches(_ precondition: PlanPrecondition) -> Bool {
    guard let current = capture(precondition.path) else { return false }
    return current.device == precondition.device && current.inode == precondition.inode
      && current.symbolicLink == precondition.symbolicLink
  }
}
