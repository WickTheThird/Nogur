import CryptoKit
import Foundation

enum DeviceIdentityError: LocalizedError, Sendable, Equatable {
  case invalidChallenge
  case invalidPrivateKey
  case notVerified
  case revoked

  var errorDescription: String? {
    switch self {
    case .invalidChallenge:
      return "The server returned an invalid device challenge."
    case .invalidPrivateKey:
      return "The saved device key is invalid."
    case .notVerified:
      return "This Mac has not completed device verification."
    case .revoked:
      return "This Mac has been revoked. Sign in from another device to restore access."
    }
  }
}

final class DeviceIdentityStore: @unchecked Sendable {
  static let shared = DeviceIdentityStore()

  private enum Account {
    static let privateKey = "device-private-key"
    static let deviceID = "device-id"
    static let deviceToken = "device-token"
    static let deviceTokenExpiresAt = "device-token-expires-at"
  }

  private let keychain: any SecureStoring
  private let lock = NSLock()

  init(
    service: String = Bundle.main.bundleIdentifier ?? "com.filipbumbu.Nogur",
    keychain: (any SecureStoring)? = nil
  ) {
    self.keychain = keychain ?? KeychainStore(service: service)
  }

  var deviceID: UUID? {
    guard let value = read(Account.deviceID) else { return nil }
    return UUID(uuidString: value)
  }

  var deviceToken: String? {
    guard
      let token = read(Account.deviceToken),
      let rawExpiry = read(Account.deviceTokenExpiresAt),
      let expiry = TimeInterval(rawExpiry),
      Date(timeIntervalSince1970: expiry) > Date().addingTimeInterval(30)
    else {
      return nil
    }
    return token
  }

  func privateKey() throws -> Curve25519.Signing.PrivateKey? {
    guard let encoded = read(Account.privateKey) else { return nil }
    guard
      let data = Data(base64Encoded: encoded),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    else {
      throw DeviceIdentityError.invalidPrivateKey
    }
    return key
  }

  func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
    if let existing = try privateKey() {
      return existing
    }

    let key = Curve25519.Signing.PrivateKey()
    try save(
      key.rawRepresentation.base64EncodedString(),
      account: Account.privateKey
    )
    return key
  }

  func saveDeviceID(_ id: UUID) throws {
    try save(id.uuidString, account: Account.deviceID)
  }

  func saveDeviceToken(_ token: String, expiresIn: Int) throws {
    let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
    try save(token, account: Account.deviceToken)
    try save(
      String(expiry.timeIntervalSince1970),
      account: Account.deviceTokenExpiresAt
    )
  }

  func clearVerification() {
    delete(Account.deviceToken)
    delete(Account.deviceTokenExpiresAt)
  }

  func clearRegistration(keepPrivateKey: Bool = true) {
    delete(Account.deviceID)
    clearVerification()
    if !keepPrivateKey {
      delete(Account.privateKey)
    }
  }

  private func read(_ account: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return try? keychain.read(account: account)
  }

  private func save(_ value: String, account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    try keychain.save(value, account: account)
  }

  private func delete(_ account: String) {
    lock.lock()
    defer { lock.unlock() }
    try? keychain.delete(account: account)
  }
}

actor DeviceIdentityManager {
  private let store: DeviceIdentityStore

  init(store: DeviceIdentityStore = .shared) {
    self.store = store
  }

  func ensureIdentity(using api: APIClient) async throws -> DeviceRecord {
    let key = try store.loadOrCreatePrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let devices: [DeviceRecord] = try await api.send(path: "devices")

    let device: DeviceRecord
    if let existing = devices.first(where: { $0.publicKey == publicKey }) {
      try store.saveDeviceID(existing.id)
      if existing.revokedAt != nil {
        store.clearVerification()
        throw DeviceIdentityError.revoked
      }
      device = existing
    } else {
      let request = DeviceRegisterRequest(
        name: Host.current().localizedName ?? "Mac",
        platform: "macos",
        publicKey: publicKey
      )
      device = try await api.send(
        path: "devices/register",
        method: .post,
        body: request
      )
      try store.saveDeviceID(device.id)
    }

    if store.deviceToken == nil || device.verifiedAt == nil {
      return try await verify(device: device, privateKey: key, using: api)
    }
    return device
  }

  func reverify(using api: APIClient) async throws -> DeviceRecord {
    guard let deviceID = store.deviceID else {
      return try await ensureIdentity(using: api)
    }
    let key = try store.loadOrCreatePrivateKey()
    let device: DeviceRecord = try await api.send(path: "devices/\(deviceID)")
    if device.revokedAt != nil {
      store.clearVerification()
      throw DeviceIdentityError.revoked
    }
    return try await verify(device: device, privateKey: key, using: api)
  }

  func clearAfterLogout() {
    store.clearVerification()
  }

  private func verify(
    device: DeviceRecord,
    privateKey: Curve25519.Signing.PrivateKey,
    using api: APIClient
  ) async throws -> DeviceRecord {
    let challenge: DeviceChallengeResponse = try await api.send(
      path: "devices/\(device.id)/challenge",
      method: .post
    )
    guard let challengeData = Data(base64Encoded: challenge.challenge) else {
      throw DeviceIdentityError.invalidChallenge
    }
    let signature = try privateKey.signature(for: challengeData)
    let response: DeviceVerificationResponse = try await api.send(
      path: "devices/\(device.id)/verify",
      method: .post,
      body: DeviceVerifyRequest(signature: signature.base64EncodedString()),
      retryAfterUnauthorized: false
    )
    try store.saveDeviceToken(
      response.deviceToken,
      expiresIn: response.expiresIn
    )
    return response.device
  }
}
