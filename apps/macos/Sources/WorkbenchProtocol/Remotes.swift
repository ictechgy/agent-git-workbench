import Foundation

public struct RemoteBranch: Decodable, Sendable, Equatable, Identifiable {
  public let name: String
  public let oid: String
  public var id: String { name }
}
public struct RemoteInfo: Decodable, Sendable, Equatable, Identifiable {
  public let name: String
  public let fetchUrl: String
  public let pushUrl: String
  public let supported: Bool
  public let problem: String?
  public let branches: [RemoteBranch]
  public var id: String { name }
}
public struct RemoteState: Decodable, Sendable, Equatable {
  public let stateHash: String
  public let repositoryPath: String
  public let branch: String?
  public let head: String?
  public let clean: Bool
  public let remotes: [RemoteInfo]
  public let upstreamRemote: String?
  public let upstreamBranch: String?
  public let ahead: UInt64?
  public let behind: UInt64?
  public var branchName: String? { branch.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 } }
}
public struct RemoteMutationResult: Decodable, Sendable {
  public let state: RemoteState?
  public let refreshRequired: Bool
  public let message: String
}
