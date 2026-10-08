import Foundation

actor RealtimeClient {
  typealias EventHandler = @Sendable (SignalingEnvelope) async -> Void
  typealias StateHandler = @Sendable (RealtimeConnectionState) async -> Void

  private let api: APIClient
  private let session: URLSession
  private let eventHandler: EventHandler
  private let stateHandler: StateHandler
  private let backoff: ReconnectBackoff

  private var connectionTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var socket: URLSessionWebSocketTask?
  private var shouldRun = false
  private var lastPong = Date.distantPast

  init(
    api: APIClient,
    session: URLSession = .shared,
    backoff: ReconnectBackoff = ReconnectBackoff(),
    eventHandler: @escaping EventHandler,
    stateHandler: @escaping StateHandler = { _ in }
  ) {
    self.api = api
    self.session = session
    self.backoff = backoff
    self.eventHandler = eventHandler
    self.stateHandler = stateHandler
  }

  func start() {
    guard connectionTask == nil else { return }
    shouldRun = true
    connectionTask = Task { await runConnectionLoop() }
  }

  func stop() {
    shouldRun = false
    heartbeatTask?.cancel()
    heartbeatTask = nil
    connectionTask?.cancel()
    connectionTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    Task { await stateHandler(.stopped) }
  }

  func send(_ envelope: SignalingEnvelope) async throws {
    guard let socket else {
      throw APIError.transport("The realtime connection is offline.")
    }
    let data = try JSONCoding.encoder.encode(envelope)
    guard let text = String(data: data, encoding: .utf8) else {
      throw APIError.invalidRequest
    }
    try await socket.send(.string(text))
  }

  private func runConnectionLoop() async {
    var attempt = 0
    while shouldRun && !Task.isCancelled {
      do {
        await stateHandler(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
        try await connectOnce()
        attempt = 0
      } catch is CancellationError {
        break
      } catch {
        guard shouldRun else { break }
        attempt += 1
        await stateHandler(.reconnecting(attempt: attempt))
        let delay = backoff.delay(for: attempt)
        try? await Task.sleep(for: .seconds(delay))
      }
    }
    socket = nil
    connectionTask = nil
    if shouldRun {
      await stateHandler(.disconnected)
    }
  }

  private func connectOnce() async throws {
    let ticket: RealtimeTicketResponse = try await api.send(
      path: "realtime/tickets",
      method: .post,
      requiresDevice: true
    )
    let url = try await api.websocketURL(ticket: ticket.ticket)
    let newSocket = session.webSocketTask(with: url)
    socket = newSocket
    lastPong = Date()
    newSocket.resume()
    await stateHandler(.connected)

    heartbeatTask = Task { [weak self] in
      await self?.heartbeatLoop(socket: newSocket)
    }
    defer {
      heartbeatTask?.cancel()
      heartbeatTask = nil
      newSocket.cancel(with: .goingAway, reason: nil)
      if socket === newSocket { socket = nil }
    }

    while shouldRun && !Task.isCancelled {
      let message = try await newSocket.receive()
      let data: Data
      switch message {
      case .data(let value): data = value
      case .string(let value): data = Data(value.utf8)
      @unknown default: continue
      }
      let envelope = try JSONCoding.decoder.decode(SignalingEnvelope.self, from: data)
      if envelope.type == "pong" {
        lastPong = Date()
      }
      await eventHandler(envelope)
      if envelope.type == "device.revoked" {
        shouldRun = false
        NotificationCenter.default.post(name: .nogurDeviceRevoked, object: nil)
        break
      }
    }
  }

  private func heartbeatLoop(socket: URLSessionWebSocketTask) async {
    while shouldRun && !Task.isCancelled {
      try? await Task.sleep(for: .seconds(20))
      guard shouldRun, !Task.isCancelled else { return }
      if Date().timeIntervalSince(lastPong) > 50 {
        socket.cancel(with: .goingAway, reason: Data("Heartbeat timed out".utf8))
        return
      }
      try? await send(SignalingEnvelope(type: "ping"))
    }
  }
}

extension Notification.Name {
  static let nogurDeviceRevoked = Notification.Name(
    "com.filipbumbu.Nogur.deviceRevoked"
  )
}
