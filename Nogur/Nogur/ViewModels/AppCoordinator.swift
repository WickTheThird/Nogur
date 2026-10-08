import Combine
import Foundation
import Network

enum DeviceListPhase: Equatable {
  case idle
  case loading
  case loaded
  case failed(String)
  case offline
}

@MainActor
final class AppCoordinator: ObservableObject {
  @Published private(set) var devices: [DeviceRecord] = []
  @Published private(set) var sessions: [RemoteSessionRecord] = []
  @Published private(set) var devicePhase: DeviceListPhase = .idle
  @Published private(set) var realtimeState: RealtimeConnectionState = .stopped
  @Published private(set) var currentDevice: DeviceRecord?
  @Published private(set) var isPreparing = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var isNetworkAvailable = true

  private let api: APIClient
  private let identityManager: DeviceIdentityManager
  private let identityStore: DeviceIdentityStore
  private let networkMonitor: NetworkAvailabilityMonitor
  let webRTC: WebRTCManager
  let screenCapture: ScreenCaptureService
  private let inputController: RemoteInputController
  private var realtime: RealtimeClient?
  private var bootstrapTask: Task<Void, Never>?
  private var monitorTask: Task<Void, Never>?
  private var preparedSessionID: UUID?

  init(
    api: APIClient = .production,
    identityManager: DeviceIdentityManager = DeviceIdentityManager(),
    identityStore: DeviceIdentityStore = .shared,
    networkMonitor: NetworkAvailabilityMonitor = NetworkAvailabilityMonitor(),
    screenCapture: ScreenCaptureService = ScreenCaptureService(),
    inputController: RemoteInputController = RemoteInputController()
  ) {
    self.api = api
    self.identityManager = identityManager
    self.identityStore = identityStore
    self.networkMonitor = networkMonitor
    self.screenCapture = screenCapture
    webRTC = WebRTCManager(
      screenCapture: screenCapture,
      inputController: inputController
    )
    self.inputController = inputController
  }

  var currentDeviceID: UUID? { identityStore.deviceID }
  var accessibilityAllowed: Bool { inputController.accessibilityAllowed }

  @discardableResult
  func requestAccessibilityPermission() -> Bool {
    inputController.requestAccessibilityPermission()
  }

  var incomingRequest: RemoteSessionRecord? {
    guard let currentDeviceID else { return nil }
    return sessions.first {
      $0.targetDeviceID == currentDeviceID && $0.status == .pending
    }
  }

  var currentSession: RemoteSessionRecord? {
    guard let currentDeviceID else { return nil }
    return sessions.first {
      !$0.status.isTerminal
        && ($0.sourceDeviceID == currentDeviceID || $0.targetDeviceID == currentDeviceID)
    }
  }

  var hasActiveControl: Bool {
    guard let session = currentSession else { return false }
    return session.status == .active
      && session.approvedCapabilities.contains(where: {
        [.inputPointer, .inputKeyboard, .inputScroll].contains($0)
      })
  }

  func deviceName(for id: UUID) -> String {
    devices.first(where: { $0.id == id })?.name ?? "Unknown Mac"
  }

  func start() {
    guard bootstrapTask == nil else { return }
    monitorTask = Task { [weak self, networkMonitor] in
      for await available in networkMonitor.updates {
        guard let self else { return }
        isNetworkAvailable = available
        if !available, devices.isEmpty {
          devicePhase = .offline
        } else if available, case .offline = devicePhase {
          await reload()
        }
      }
    }
    bootstrapTask = Task { [weak self] in
      await self?.bootstrap()
    }
    inputController.emergencyStop = { [weak self] in
      Task { @MainActor in
        await self?.endCurrentSession(reason: "local_emergency_stop")
      }
    }
  }

  func stop() {
    bootstrapTask?.cancel()
    bootstrapTask = nil
    monitorTask?.cancel()
    monitorTask = nil
    if let realtime {
      Task { await realtime.stop() }
    }
    realtime = nil
    webRTC.close()
    preparedSessionID = nil
    sessions = []
  }

  func reload() async {
    guard isNetworkAvailable else {
      if devices.isEmpty { devicePhase = .offline }
      return
    }
    if devices.isEmpty { devicePhase = .loading }
    do {
      async let loadedDevices: [DeviceRecord] = api.send(path: "devices")
      async let loadedSessions: [RemoteSessionRecord] = api.send(
        path: "sessions",
        requiresDevice: true
      )
      devices = try await loadedDevices
      sessions = try await loadedSessions
      currentDevice = devices.first(where: { $0.id == currentDeviceID })
      devicePhase = .loaded
      errorMessage = nil
      await synchronizeWebRTC()
    } catch is CancellationError {
      return
    } catch {
      devicePhase = devices.isEmpty ? .failed(error.localizedDescription) : .loaded
      errorMessage = error.localizedDescription
    }
  }

  func retryIdentity() async {
    await bootstrap()
  }

  func revoke(_ device: DeviceRecord) async {
    do {
      try await api.delete(path: "devices/\(device.id)")
      if device.id == currentDeviceID {
        identityStore.clearVerification()
        await handleCurrentDeviceRevoked()
      } else {
        await reload()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createSession(
    targeting device: DeviceRecord,
    capabilities: [SessionCapability]
  ) async {
    guard device.id != currentDeviceID else { return }
    do {
      let created: RemoteSessionRecord = try await api.send(
        path: "sessions",
        method: .post,
        body: SessionCreateRequest(
          targetDeviceID: device.id,
          requestedCapabilities: capabilities,
          capture: CaptureRequest()
        ),
        requiresDevice: true
      )
      upsert(created)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func accept(_ session: RemoteSessionRecord, capabilities: [SessionCapability]) async {
    do {
      let accepted: RemoteSessionRecord = try await api.send(
        path: "sessions/\(session.id)/accept",
        method: .post,
        body: SessionAcceptRequest(approvedCapabilities: capabilities),
        requiresDevice: true
      )
      upsert(accepted)
      errorMessage = nil
      await synchronizeWebRTC()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reject(_ session: RemoteSessionRecord) async {
    do {
      let rejected: RemoteSessionRecord = try await api.send(
        path: "sessions/\(session.id)/reject",
        method: .post,
        requiresDevice: true
      )
      upsert(rejected)
      webRTC.close()
      preparedSessionID = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func endCurrentSession(reason: String = "ended_by_user") async {
    guard let session = currentSession else { return }
    do {
      let ended: RemoteSessionRecord = try await api.send(
        path: "sessions/\(session.id)/end",
        method: .post,
        body: SessionEndRequest(reason: reason),
        requiresDevice: true
      )
      upsert(ended)
      webRTC.close()
      preparedSessionID = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func bootstrap() async {
    guard !isPreparing else { return }
    isPreparing = true
    devicePhase = .loading
    defer {
      isPreparing = false
      bootstrapTask = nil
    }
    do {
      currentDevice = try await identityManager.ensureIdentity(using: api)
      await reload()
      startRealtime()
    } catch is CancellationError {
      return
    } catch {
      devicePhase = isNetworkAvailable ? .failed(error.localizedDescription) : .offline
      errorMessage = error.localizedDescription
    }
  }

  private func startRealtime() {
    guard realtime == nil else { return }
    let client = RealtimeClient(
      api: api,
      eventHandler: { [weak self] envelope in
        await self?.handle(envelope)
      },
      stateHandler: { [weak self] state in
        await self?.setRealtimeState(state)
      }
    )
    realtime = client
    Task { await client.start() }
  }

  private func setRealtimeState(_ state: RealtimeConnectionState) {
    realtimeState = state
    if state == .connected {
      Task { await synchronizeWebRTC() }
    }
  }

  private func handle(_ envelope: SignalingEnvelope) async {
    switch envelope.type {
    case "device.revoked":
      await handleCurrentDeviceRevoked()
    case "webrtc.offer", "webrtc.answer", "webrtc.ice_candidate":
      do {
        try await webRTC.handle(envelope)
      } catch {
        errorMessage = error.localizedDescription
      }
    case "device.connected", "session.requested", "session.accepted",
      "session.rejected", "session.connecting", "session.active",
      "session.failed", "session.expired", "session.ended":
      await reload()
    default:
      break
    }
  }

  private func synchronizeWebRTC() async {
    guard let active = currentSession else {
      if preparedSessionID != nil {
        webRTC.close()
        preparedSessionID = nil
      }
      return
    }
    guard [.accepted, .connecting, .active].contains(active.status) else { return }
    guard preparedSessionID != active.id, let currentDeviceID else { return }
    do {
      let transport: SessionTransportResponse = try await api.send(
        path: "sessions/\(active.id)/transport",
        method: .post,
        requiresDevice: true
      )
      guard let realtime else { throw APIError.transport("Realtime is not connected.") }
      preparedSessionID = active.id
      try await webRTC.prepare(
        session: active,
        transport: transport,
        isSource: active.sourceDeviceID == currentDeviceID,
        signal: { envelope in
          try await realtime.send(envelope)
        }
      )
    } catch {
      preparedSessionID = nil
      errorMessage = error.localizedDescription
      if let realtime {
        try? await realtime.send(SignalingEnvelope(
          type: "session.failed",
          sessionID: active.id,
          payload: ["reason": .string("local_setup_failed")]
        ))
      }
    }
  }

  private func handleCurrentDeviceRevoked() async {
    if let realtime { await realtime.stop() }
    realtime = nil
    webRTC.close()
    preparedSessionID = nil
    currentDevice = currentDevice.map {
      DeviceRecord(
        id: $0.id,
        userID: $0.userID,
        name: $0.name,
        platform: $0.platform,
        publicKey: $0.publicKey,
        createdAt: $0.createdAt,
        lastSeenAt: $0.lastSeenAt,
        verifiedAt: $0.verifiedAt,
        revokedAt: Date(),
        online: false
      )
    }
    errorMessage = DeviceIdentityError.revoked.localizedDescription
  }

  private func upsert(_ session: RemoteSessionRecord) {
    sessions.removeAll(where: { $0.id == session.id })
    sessions.insert(session, at: 0)
  }
}

final class NetworkAvailabilityMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.filipbumbu.Nogur.network")
  private let stream: AsyncStream<Bool>
  private let continuation: AsyncStream<Bool>.Continuation

  init() {
    let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    stream = pair.stream
    continuation = pair.continuation
    monitor.pathUpdateHandler = { [continuation] path in
      continuation.yield(path.status == .satisfied)
    }
    monitor.start(queue: queue)
  }

  var updates: AsyncStream<Bool> { stream }

  func stop() {
    monitor.cancel()
    continuation.finish()
  }
}
