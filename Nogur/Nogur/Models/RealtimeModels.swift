import Foundation

enum JSONValue: Codable, Sendable, Equatable {
  case array([JSONValue])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: JSONValue])
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .number(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }
}

struct SignalingEnvelope: Codable, Sendable, Equatable {
  let version: Int
  let eventID: UUID
  let type: String
  let sessionID: UUID?
  let sentAt: Date
  let payload: [String: JSONValue]

  private enum CodingKeys: String, CodingKey {
    case version
    case eventID = "eventId"
    case type
    case sessionID = "sessionId"
    case sentAt
    case payload
  }

  init(
    type: String,
    sessionID: UUID? = nil,
    payload: [String: JSONValue] = [:],
    eventID: UUID = UUID(),
    sentAt: Date = Date()
  ) {
    version = 1
    self.eventID = eventID
    self.type = type
    self.sessionID = sessionID
    self.sentAt = sentAt
    self.payload = payload
  }
}

struct RealtimeTicketResponse: Decodable, Sendable {
  let ticket: String
  let expiresAt: Date
}

enum RealtimeConnectionState: Sendable, Equatable {
  case connected
  case connecting
  case disconnected
  case reconnecting(attempt: Int)
  case stopped
}

struct ReconnectBackoff: Sendable {
  let maximum: TimeInterval

  init(maximum: TimeInterval = 30) {
    self.maximum = maximum
  }

  func delay(for attempt: Int) -> TimeInterval {
    min(maximum, pow(2, Double(max(0, attempt - 1))))
  }
}

struct PendingSignalBuffer: Sendable {
  private var storage: [UUID: [SignalingEnvelope]] = [:]

  mutating func append(_ envelope: SignalingEnvelope, for sessionID: UUID) {
    storage[sessionID, default: []].append(envelope)
  }

  mutating func drain(for sessionID: UUID) -> [SignalingEnvelope] {
    storage.removeValue(forKey: sessionID) ?? []
  }

  mutating func remove(for sessionID: UUID) {
    storage.removeValue(forKey: sessionID)
  }

  mutating func removeAll() {
    storage.removeAll()
  }
}
