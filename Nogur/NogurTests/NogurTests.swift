import CryptoKit
import CoreGraphics
import Foundation
import Testing
@testable import Nogur

@Suite(.serialized)
struct NogurTests {
  @Test
  func apiRefreshesOnceAndRetriesConcurrentRequests() async throws {
    let tokenStore = InMemoryTokenStore(
      accessToken: "expired",
      refreshToken: "refresh-token"
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let counts = RequestCounts()

    MockURLProtocol.handler = { request in
      let path = request.url?.path ?? ""
      if path.hasSuffix("/auth/refresh") {
        counts.incrementRefresh()
        try await Task.sleep(for: .milliseconds(50))
        return MockURLProtocol.response(
          request,
          status: 200,
          json: #"{"access_token":"fresh","refresh_token":"new-refresh","token_type":"bearer","expires_in":900}"#
        )
      }
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" {
        return MockURLProtocol.response(request, status: 200, json: #"{"value":"ok"}"#)
      }
      return MockURLProtocol.response(request, status: 401, json: #"{"detail":"Expired"}"#)
    }

    let api = APIClient(
      baseURL: URL(string: "https://example.test/v1")!,
      tokenStore: tokenStore,
      identityStore: DeviceIdentityStore(keychain: InMemorySecureStore()),
      session: session
    )
    async let first: TestPayload = api.send(path: "protected")
    async let second: TestPayload = api.send(path: "protected")
    let values = try await [first, second]

    #expect(values.allSatisfy { $0.value == "ok" })
    #expect(counts.refreshes == 1)
    #expect(tokenStore.accessToken == "fresh")
  }

  @Test
  func apiRequestCanBeCancelled() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    MockURLProtocol.handler = { request in
      try await Task.sleep(for: .seconds(5))
      return MockURLProtocol.response(request, status: 200, json: #"{"value":"late"}"#)
    }
    let api = APIClient(
      baseURL: URL(string: "https://example.test/v1")!,
      tokenStore: InMemoryTokenStore(accessToken: "valid", refreshToken: "refresh"),
      identityStore: DeviceIdentityStore(keychain: InMemorySecureStore()),
      session: session
    )
    let request = Task<TestPayload, Error> { try await api.send(path: "slow") }
    request.cancel()

    await #expect(throws: APIError.self) {
      _ = try await request.value
    }
  }

  @Test
  func devicePrivateKeyPersistsAndSignsChallenges() throws {
    let secureStore = InMemorySecureStore()
    let first = DeviceIdentityStore(service: "tests", keychain: secureStore)
    let original = try first.loadOrCreatePrivateKey()
    let second = DeviceIdentityStore(service: "tests", keychain: secureStore)
    let restored = try second.loadOrCreatePrivateKey()

    #expect(original.rawRepresentation == restored.rawRepresentation)
    let challenge = Data("server-challenge".utf8)
    let signature = try restored.signature(for: challenge)
    #expect(restored.publicKey.isValidSignature(signature, for: challenge))
  }

  @Test
  func deviceRegistrationAndTokenPersist() throws {
    let secureStore = InMemorySecureStore()
    let store = DeviceIdentityStore(service: "tests", keychain: secureStore)
    let id = UUID()
    try store.saveDeviceID(id)
    try store.saveDeviceToken("device-token", expiresIn: 600)

    let restored = DeviceIdentityStore(service: "tests", keychain: secureStore)
    #expect(restored.deviceID == id)
    #expect(restored.deviceToken == "device-token")
  }

  @Test
  func signalingEnvelopeRoundTrips() throws {
    let sessionID = UUID()
    let envelope = SignalingEnvelope(
      type: "webrtc.ice_candidate",
      sessionID: sessionID,
      payload: [
        "candidate": .string("candidate:1"),
        "sdp_mline_index": .number(0)
      ],
      sentAt: Date(timeIntervalSince1970: 1_791_446_400)
    )
    let encoded = try JSONCoding.encoder.encode(envelope)
    let decoded = try JSONCoding.decoder.decode(SignalingEnvelope.self, from: encoded)
    #expect(decoded == envelope)
  }

  @Test
  func reconnectBackoffIsExponentialAndCapped() {
    let backoff = ReconnectBackoff(maximum: 30)
    #expect(backoff.delay(for: 1) == 1)
    #expect(backoff.delay(for: 2) == 2)
    #expect(backoff.delay(for: 6) == 30)
    #expect(backoff.delay(for: 20) == 30)
  }

  @Test
  func sessionTerminalStatesAreComplete() {
    #expect(RemoteSessionStatus.ended.isTerminal)
    #expect(RemoteSessionStatus.failed.isTerminal)
    #expect(RemoteSessionStatus.expired.isTerminal)
    #expect(RemoteSessionStatus.rejected.isTerminal)
    #expect(!RemoteSessionStatus.pending.isTerminal)
    #expect(!RemoteSessionStatus.active.isTerminal)
  }

  @Test
  func coordinateMappingClampsAndUsesSelectedDisplay() {
    let frame = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
    #expect(CoordinateMapper.point(NormalizedPoint(x: 0.5, y: 0.25), in: frame)
      == CGPoint(x: 2720, y: 360))
    #expect(CoordinateMapper.point(NormalizedPoint(x: -1, y: 2), in: frame)
      == CGPoint(x: 1440, y: 1440))
  }

  @Test
  func aspectFitCoordinatesIgnoreLetterboxBars() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let content = CoordinateMapper.aspectFitRect(
      for: CGSize(width: 1920, height: 1080),
      in: bounds
    )
    #expect(abs(content.minX) < 0.001)
    #expect(abs(content.minY - 218.75) < 0.001)
    #expect(abs(content.width - 1000) < 0.001)
    #expect(abs(content.height - 562.5) < 0.001)
    #expect(CoordinateMapper.normalizedPoint(CGPoint(x: 500, y: 100), contentRect: content) == nil)
    #expect(CoordinateMapper.normalizedPoint(CGPoint(x: 500, y: 500), contentRect: content)
      == NormalizedPoint(x: 0.5, y: 0.5))
  }

  @Test
  func disconnectRecoveryReleasesEveryHeldInput() {
    var state = HeldInputState()
    state.updateKey(12, down: true)
    state.updateKey(13, down: true)
    state.updateButton(0, down: true)
    let released = state.drain()

    #expect(released.keys == [12, 13])
    #expect(released.buttons == [0])
    #expect(state.keys.isEmpty)
    #expect(state.buttons.isEmpty)
  }

  @Test
  func screenCaptureSizingPreservesAspectAndResolutionLimit() {
    let result = ScreenCaptureService.fittedSize(
      source: CGSize(width: 5120, height: 2880),
      maximum: CGSize(width: 1920, height: 1080)
    )
    #expect(result == CGSize(width: 1920, height: 1080))
  }

  @Test
  func serverDatesDecodeWithFractionalSeconds() throws {
    struct Timestamp: Decodable { let value: Date }
    let data = Data(#"{"value":"2026-10-08T09:15:30.123456Z"}"#.utf8)
    let decoded = try JSONCoding.decoder.decode(Timestamp.self, from: data)
    #expect(decoded.value.timeIntervalSince1970 > 0)
  }
}

private struct TestPayload: Decodable, Sendable {
  let value: String
}

private final class InMemorySecureStore: SecureStoring, @unchecked Sendable {
  private var values: [String: String] = [:]
  private let lock = NSLock()

  func save(_ value: String, account: String) throws {
    lock.withLock { values[account] = value }
  }

  func read(account: String) throws -> String? {
    lock.withLock { values[account] }
  }

  func delete(account: String) throws {
    lock.withLock { _ = values.removeValue(forKey: account) }
  }
}

private final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var access: String?
  private var refresh: String?

  init(accessToken: String?, refreshToken: String?) {
    access = accessToken
    refresh = refreshToken
  }

  var accessToken: String? { lock.withLock { access } }
  var refreshToken: String? { lock.withLock { refresh } }
  var emailAddress: String? { nil }
  var hasSession: Bool { accessToken != nil && refreshToken != nil }

  func save(_ tokens: TokenPair, emailAddress: String?) throws {
    lock.withLock {
      access = tokens.accessToken
      refresh = tokens.refreshToken
    }
  }

  func clear() {
    lock.withLock {
      access = nil
      refresh = nil
    }
  }
}

private final class RequestCounts: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var refreshes: Int { lock.withLock { value } }
  func incrementRefresh() { lock.withLock { value += 1 } }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Task {
      do {
        guard let handler = Self.handler else { throw URLError(.badServerResponse) }
        let (response, data) = try await handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {}

  static func response(
    _ request: URLRequest,
    status: Int,
    json: String
  ) -> (HTTPURLResponse, Data) {
    (
      HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!,
      Data(json.utf8)
    )
  }
}
