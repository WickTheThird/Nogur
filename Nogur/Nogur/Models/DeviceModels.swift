import Foundation

enum DeviceConnectionState: String, Sendable {
  case offline
  case online
  case revoked
  case unverified
}

struct DeviceRecord: Codable, Identifiable, Sendable, Equatable {
  let id: UUID
  let userID: UUID
  let name: String
  let platform: String
  let publicKey: String
  let createdAt: Date
  let lastSeenAt: Date?
  let verifiedAt: Date?
  let revokedAt: Date?
  let online: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case userID = "userId"
    case name
    case platform
    case publicKey
    case createdAt
    case lastSeenAt
    case verifiedAt
    case revokedAt
    case online
  }

  var state: DeviceConnectionState {
    if revokedAt != nil { return .revoked }
    if verifiedAt == nil { return .unverified }
    return online ? .online : .offline
  }
}

struct DeviceRegisterRequest: Encodable, Sendable {
  let name: String
  let platform: String
  let publicKey: String
}

struct DeviceChallengeResponse: Decodable, Sendable {
  let challenge: String
  let expiresAt: Date
}

struct DeviceVerifyRequest: Encodable, Sendable {
  let signature: String
}

struct DeviceVerificationResponse: Decodable, Sendable {
  let device: DeviceRecord
  let deviceToken: String
  let expiresIn: Int
}
