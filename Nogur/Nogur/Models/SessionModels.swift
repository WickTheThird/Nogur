import Foundation

enum SessionCapability: String, Codable, CaseIterable, Sendable, Identifiable {
  case clipboardRead = "clipboard.read"
  case clipboardWrite = "clipboard.write"
  case inputKeyboard = "input.keyboard"
  case inputPointer = "input.pointer"
  case inputScroll = "input.scroll"
  case screenView = "screen.view"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .screenView: "View screen"
    case .inputPointer: "Control pointer"
    case .inputKeyboard: "Use keyboard"
    case .inputScroll: "Scroll"
    case .clipboardRead: "Read clipboard"
    case .clipboardWrite: "Write clipboard"
    }
  }
}

enum RemoteSessionStatus: String, Codable, Sendable {
  case accepted
  case active
  case connecting
  case ended
  case expired
  case failed
  case pending
  case rejected

  var isTerminal: Bool {
    [.ended, .expired, .failed, .rejected].contains(self)
  }
}

struct CaptureRequest: Codable, Sendable, Equatable {
  let type: String
  let preferredWidth: Int
  let preferredHeight: Int
  let preferredFps: Int

  init(
    type: String = "display",
    preferredWidth: Int = 1920,
    preferredHeight: Int = 1080,
    preferredFps: Int = 30
  ) {
    self.type = type
    self.preferredWidth = preferredWidth
    self.preferredHeight = preferredHeight
    self.preferredFps = preferredFps
  }
}

struct SessionCreateRequest: Encodable, Sendable {
  let targetDeviceID: UUID
  let requestedCapabilities: [SessionCapability]
  let capture: CaptureRequest
}

struct SessionAcceptRequest: Encodable, Sendable {
  let approvedCapabilities: [SessionCapability]
}

struct SessionEndRequest: Encodable, Sendable {
  let reason: String
}

struct RemoteSessionRecord: Codable, Identifiable, Sendable, Equatable {
  let id: UUID
  let userID: UUID
  let sourceDeviceID: UUID
  let targetDeviceID: UUID
  let status: RemoteSessionStatus
  let requestedCapabilities: [SessionCapability]
  let approvedCapabilities: [SessionCapability]
  let capture: CaptureRequest
  let createdAt: Date
  let expiresAt: Date
  let acceptedAt: Date?
  let connectedAt: Date?
  let endedAt: Date?
  let endReason: String?
  let sourceIP: String?
  let targetIP: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case userID = "userId"
    case sourceDeviceID = "sourceDeviceId"
    case targetDeviceID = "targetDeviceId"
    case status
    case requestedCapabilities
    case approvedCapabilities
    case capture
    case createdAt
    case expiresAt
    case acceptedAt
    case connectedAt
    case endedAt
    case endReason
    case sourceIP = "sourceIp"
    case targetIP = "targetIp"
  }
}

struct IceServerRecord: Decodable, Sendable, Equatable {
  let urls: [String]
  let username: String?
  let credential: String?
}

struct SessionTransportResponse: Decodable, Sendable {
  let expiresAt: Date
  let iceServers: [IceServerRecord]
}
