@preconcurrency import WebRTC
import AVFoundation
import Combine
import Foundation
import SwiftUI

enum WebRTCManagerState: Equatable, Sendable {
  case idle
  case negotiating
  case connected
  case failed(String)
  case closed
}

enum WebRTCManagerError: LocalizedError {
  case peerCreationFailed
  case sessionDescriptionFailed(String)
  case notReady

  var errorDescription: String? {
    switch self {
    case .peerCreationFailed: "Could not create the secure peer connection."
    case .sessionDescriptionFailed(let message): message
    case .notReady: "The peer connection is not ready."
    }
  }
}

@MainActor
final class WebRTCManager: NSObject, ObservableObject {
  typealias SignalSender = @Sendable (SignalingEnvelope) async throws -> Void

  @Published private(set) var state: WebRTCManagerState = .idle
  @Published private(set) var remoteVideoTrack: RTCVideoTrack?
  @Published private(set) var reliableChannelReady = false

  private let factory: RTCPeerConnectionFactory
  private let screenCapture: ScreenCaptureService
  private let inputController: RemoteInputController
  private var peer: RTCPeerConnection?
  private var reliableChannel: RTCDataChannel?
  private var pointerChannel: RTCDataChannel?
  private var session: RemoteSessionRecord?
  private var isSource = false
  private var signal: SignalSender?
  private var videoSource: RTCVideoSource?
  private var videoCapturer: RTCVideoCapturer?

  init(
    screenCapture: ScreenCaptureService,
    inputController: RemoteInputController
  ) {
    self.screenCapture = screenCapture
    self.inputController = inputController
    RTCInitializeSSL()
    factory = RTCPeerConnectionFactory(
      encoderFactory: RTCDefaultVideoEncoderFactory(),
      decoderFactory: RTCDefaultVideoDecoderFactory()
    )
    super.init()
  }

  func prepare(
    session: RemoteSessionRecord,
    transport: SessionTransportResponse,
    isSource: Bool,
    signal: @escaping SignalSender
  ) async throws {
    close()
    self.session = session
    self.isSource = isSource
    self.signal = signal
    state = .negotiating

    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    configuration.continualGatheringPolicy = .gatherContinually
    configuration.iceServers = transport.iceServers.map {
      RTCIceServer(
        urlStrings: $0.urls,
        username: $0.username,
        credential: $0.credential
      )
    }
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: nil,
      optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
    )
    guard let connection = factory.peerConnection(
      with: configuration,
      constraints: constraints,
      delegate: self
    ) else {
      throw WebRTCManagerError.peerCreationFailed
    }
    peer = connection

    if !isSource,
      session.approvedCapabilities.contains(.screenView) {
      try await addScreenTrack(to: connection, capture: session.capture)
    }

    if isSource {
      makeDataChannels(on: connection)
      try await createAndSendOffer()
    }
  }

  func handle(_ envelope: SignalingEnvelope) async throws {
    guard envelope.sessionID == session?.id, let peer else { return }
    switch envelope.type {
    case "webrtc.offer":
      guard !isSource, let sdp = envelope.payload["sdp"]?.stringValue else { return }
      try await setRemote(RTCSessionDescription(type: .offer, sdp: sdp), on: peer)
      let answer = try await createAnswer(on: peer)
      try await setLocal(answer, on: peer)
      try await signal?(SignalingEnvelope(
        type: "webrtc.answer",
        sessionID: session?.id,
        payload: ["sdp": .string(answer.sdp)]
      ))
    case "webrtc.answer":
      guard isSource, let sdp = envelope.payload["sdp"]?.stringValue else { return }
      try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp), on: peer)
    case "webrtc.ice_candidate":
      guard let candidate = envelope.payload["candidate"]?.stringValue else { return }
      let mid = envelope.payload["sdp_mid"]?.stringValue
      let index = Int32(envelope.payload["sdp_mline_index"]?.numberValue ?? 0)
      try await addCandidate(
        RTCIceCandidate(sdp: candidate, sdpMLineIndex: index, sdpMid: mid),
        on: peer
      )
    default:
      break
    }
  }

  func sendInput(_ event: RemoteInputEvent, preferReliable: Bool) throws {
    guard isSource, state == .connected else { throw WebRTCManagerError.notReady }
    guard let session, Self.isAllowed(event, by: Set(session.approvedCapabilities)) else {
      throw WebRTCManagerError.notReady
    }
    guard let data = try? JSONEncoder().encode(event) else { return }
    let channel = preferReliable ? reliableChannel : pointerChannel
    guard channel?.readyState == .open else { throw WebRTCManagerError.notReady }
    _ = channel?.sendData(RTCDataBuffer(data: data, isBinary: false))
  }

  private static func isAllowed(
    _ event: RemoteInputEvent,
    by capabilities: Set<SessionCapability>
  ) -> Bool {
    switch event {
    case .pointerMove, .mouseButton:
      capabilities.contains(.inputPointer)
    case .scroll:
      capabilities.contains(.inputScroll)
    case .key:
      capabilities.contains(.inputKeyboard)
    }
  }

  func close() {
    screenCapture.frameHandler = nil
    Task { await screenCapture.stop() }
    inputController.end()
    reliableChannel?.close()
    pointerChannel?.close()
    reliableChannel = nil
    pointerChannel = nil
    reliableChannelReady = false
    peer?.close()
    peer = nil
    remoteVideoTrack = nil
    videoCapturer = nil
    videoSource = nil
    session = nil
    signal = nil
    state = .closed
  }

  private func createAndSendOffer() async throws {
    guard let peer, let session else { throw WebRTCManagerError.notReady }
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: [
        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
        kRTCMediaConstraintsOfferToReceiveVideo:
          session.requestedCapabilities.contains(.screenView)
            ? kRTCMediaConstraintsValueTrue
            : kRTCMediaConstraintsValueFalse
      ],
      optionalConstraints: nil
    )
    let offer = try await createOffer(on: peer, constraints: constraints)
    try await setLocal(offer, on: peer)
    try await signal?(SignalingEnvelope(
      type: "webrtc.offer",
      sessionID: session.id,
      payload: ["sdp": .string(offer.sdp)]
    ))
  }

  private func makeDataChannels(on peer: RTCPeerConnection) {
    let reliable = RTCDataChannelConfiguration()
    reliable.isOrdered = true
    reliableChannel = peer.dataChannel(forLabel: "nogur.control.reliable", configuration: reliable)
    reliableChannel?.delegate = self

    let pointer = RTCDataChannelConfiguration()
    pointer.isOrdered = false
    pointer.maxRetransmits = 0
    pointerChannel = peer.dataChannel(forLabel: "nogur.control.pointer", configuration: pointer)
    pointerChannel?.delegate = self
  }

  private func addScreenTrack(
    to peer: RTCPeerConnection,
    capture: CaptureRequest
  ) async throws {
    let source = factory.videoSource(forScreenCast: true)
    source.adaptOutputFormat(
      toWidth: Int32(capture.preferredWidth),
      height: Int32(capture.preferredHeight),
      fps: Int32(capture.preferredFps)
    )
    let capturer = RTCVideoCapturer(delegate: source)
    let track = factory.videoTrack(with: source, trackId: "nogur-screen")
    _ = peer.add(track, streamIds: ["nogur-screen-stream"])
    videoSource = source
    videoCapturer = capturer

    screenCapture.frameHandler = { [weak source, weak capturer] pixelBuffer, timestamp in
      guard let source, let capturer else { return }
      let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
      let nanos = Int64(CMTimeGetSeconds(timestamp) * 1_000_000_000)
      let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: nanos)
      source.capturer(capturer, didCapture: frame)
    }
    try await screenCapture.start(
      width: capture.preferredWidth,
      height: capture.preferredHeight,
      fps: capture.preferredFps
    )
  }

  private func createOffer(
    on peer: RTCPeerConnection,
    constraints: RTCMediaConstraints
  ) async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { continuation in
      peer.offer(for: constraints) { sdp, error in
        if let sdp { continuation.resume(returning: sdp) }
        else { continuation.resume(throwing: WebRTCManagerError.sessionDescriptionFailed(error?.localizedDescription ?? "Could not create an offer.")) }
      }
    }
  }

  private func createAnswer(on peer: RTCPeerConnection) async throws -> RTCSessionDescription {
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    return try await withCheckedThrowingContinuation { continuation in
      peer.answer(for: constraints) { sdp, error in
        if let sdp { continuation.resume(returning: sdp) }
        else { continuation.resume(throwing: WebRTCManagerError.sessionDescriptionFailed(error?.localizedDescription ?? "Could not create an answer.")) }
      }
    }
  }

  private func setLocal(_ sdp: RTCSessionDescription, on peer: RTCPeerConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setLocalDescription(sdp) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func setRemote(_ sdp: RTCSessionDescription, on peer: RTCPeerConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setRemoteDescription(sdp) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func addCandidate(_ candidate: RTCIceCandidate, on peer: RTCPeerConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.add(candidate) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }
}

extension JSONValue {
  var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }
}

extension WebRTCManager: RTCPeerConnectionDelegate {
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
  nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didGenerate candidate: RTCIceCandidate
  ) {
    Task { @MainActor [weak self] in
      guard let self, let session, let signal else { return }
      try? await signal(SignalingEnvelope(
        type: "webrtc.ice_candidate",
        sessionID: session.id,
        payload: [
          "candidate": .string(candidate.sdp),
          "sdp_mid": candidate.sdpMid.map(JSONValue.string) ?? .null,
          "sdp_mline_index": .number(Double(candidate.sdpMLineIndex))
        ]
      ))
    }
  }

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didOpen dataChannel: RTCDataChannel
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if dataChannel.label == "nogur.control.pointer" { pointerChannel = dataChannel }
      else { reliableChannel = dataChannel }
      dataChannel.delegate = self
    }
  }

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCPeerConnectionState
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      switch newState {
      case .connected:
        state = .connected
        if let session, let signal {
          try? await signal(SignalingEnvelope(type: "session.active", sessionID: session.id))
        }
        if !isSource, let session {
          let displayID = screenCapture.selectedDisplayID ?? CGMainDisplayID()
          inputController.begin(capabilities: session.approvedCapabilities, displayID: displayID)
        }
      case .failed:
        state = .failed("WebRTC negotiation failed.")
        inputController.end()
        if let session, let signal {
          try? await signal(SignalingEnvelope(
            type: "session.failed",
            sessionID: session.id,
            payload: ["reason": .string("ice_connection_failed")]
          ))
        }
      case .closed:
        state = .closed
        inputController.end()
      default:
        break
      }
    }
  }

  nonisolated func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didAdd rtpReceiver: RTCRtpReceiver,
    streams mediaStreams: [RTCMediaStream]
  ) {
    guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
    Task { @MainActor [weak self] in self?.remoteVideoTrack = track }
  }
}

extension WebRTCManager: RTCDataChannelDelegate {
  nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if dataChannel.label == "nogur.control.reliable" {
        reliableChannelReady = dataChannel.readyState == .open
        if reliableChannelReady, isSource {
          let hello = RTCDataBuffer(data: Data("nogur-ready".utf8), isBinary: false)
          _ = dataChannel.sendData(hello)
        }
      }
    }
  }

  nonisolated func dataChannel(
    _ dataChannel: RTCDataChannel,
    didReceiveMessageWith buffer: RTCDataBuffer
  ) {
    guard buffer.data != Data("nogur-ready".utf8),
      let event = try? JSONDecoder().decode(RemoteInputEvent.self, from: buffer.data)
    else { return }
    inputController.handle(event)
  }
}

struct InteractiveRemoteVideoView: NSViewRepresentable {
  let track: RTCVideoTrack
  let send: (RemoteInputEvent, Bool) -> Void

  func makeNSView(context: Context) -> RemoteControlNSView {
    let view = RemoteControlNSView()
    view.track = track
    view.send = send
    return view
  }

  func updateNSView(_ nsView: RemoteControlNSView, context: Context) {
    if nsView.track !== track { nsView.track = track }
    nsView.send = send
  }

  static func dismantleNSView(_ nsView: RemoteControlNSView, coordinator: ()) {
    nsView.track = nil
  }
}

final class RemoteControlNSView: NSView, RTCVideoViewDelegate {
  var send: ((RemoteInputEvent, Bool) -> Void)?
  var track: RTCVideoTrack? {
    didSet {
      if let oldValue { oldValue.remove(videoView) }
      if let track { track.add(videoView) }
    }
  }

  private let videoView = RTCMTLNSVideoView()
  private var trackingAreaReference: NSTrackingArea?
  private var videoSize = CGSize.zero

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    videoView.delegate = self
    videoView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(videoView)
    NSLayoutConstraint.activate([
      videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
      videoView.topAnchor.constraint(equalTo: topAnchor),
      videoView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  required init?(coder: NSCoder) { nil }

  override var acceptsFirstResponder: Bool { true }

  func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
    videoSize = size
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingAreaReference = area
  }

  override func mouseMoved(with event: NSEvent) { sendPointer(event) }
  override func mouseDragged(with event: NSEvent) { sendPointer(event) }
  override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    sendButton(event, button: 0, down: true)
  }

  override func mouseUp(with event: NSEvent) { sendButton(event, button: 0, down: false) }
  override func rightMouseDown(with event: NSEvent) { sendButton(event, button: 1, down: true) }
  override func rightMouseUp(with event: NSEvent) { sendButton(event, button: 1, down: false) }

  override func otherMouseDown(with event: NSEvent) {
    sendButton(event, button: Int(event.buttonNumber), down: true)
  }

  override func otherMouseUp(with event: NSEvent) {
    sendButton(event, button: Int(event.buttonNumber), down: false)
  }

  override func scrollWheel(with event: NSEvent) {
    send?(.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY), false)
  }

  override func keyDown(with event: NSEvent) {
    send?(.key(code: event.keyCode, down: true, flags: UInt64(event.modifierFlags.rawValue)), true)
  }

  override func keyUp(with event: NSEvent) {
    send?(.key(code: event.keyCode, down: false, flags: UInt64(event.modifierFlags.rawValue)), true)
  }

  private func sendPointer(_ event: NSEvent) {
    guard let point = normalizedPoint(for: event) else { return }
    send?(.pointerMove(point), false)
  }

  private func sendButton(_ event: NSEvent, button: Int, down: Bool) {
    guard let point = normalizedPoint(for: event) else { return }
    send?(.mouseButton(button: button, down: down, point: point), true)
  }

  private func normalizedPoint(for event: NSEvent) -> NormalizedPoint? {
    let point = convert(event.locationInWindow, from: nil)
    let contentRect = CoordinateMapper.aspectFitRect(for: videoSize, in: bounds)
    guard let normalized = CoordinateMapper.normalizedPoint(point, contentRect: contentRect) else {
      return nil
    }
    return NormalizedPoint(x: normalized.x, y: 1 - normalized.y)
  }
}
