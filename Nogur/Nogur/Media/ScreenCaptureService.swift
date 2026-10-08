import AppKit
import AVFoundation
import Combine
import CoreGraphics
import ScreenCaptureKit

struct CapturableDisplay: Identifiable, Hashable, Sendable {
  let id: CGDirectDisplayID
  let name: String
  let width: Int
  let height: Int
}

enum ScreenCaptureState: Equatable, Sendable {
  case idle
  case permissionDenied
  case preparing
  case capturing
  case failed(String)
}

final class ScreenCaptureService: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
  @Published private(set) var displays: [CapturableDisplay] = []
  @Published var selectedDisplayID: CGDirectDisplayID?
  @Published private(set) var state: ScreenCaptureState = .idle

  var frameHandler: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

  private let outputQueue = DispatchQueue(
    label: "com.filipbumbu.Nogur.screen-capture",
    qos: .userInteractive
  )
  private var stream: SCStream?
  private var content: SCShareableContent?
  private var workspaceObservers: [NSObjectProtocol] = []

  override init() {
    super.init()
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.screensDidSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification
    ] {
      workspaceObservers.append(center.addObserver(
        forName: name,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { await self?.stop() }
      })
    }
  }

  deinit {
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  var hasPermission: Bool {
    CGPreflightScreenCaptureAccess()
  }

  @discardableResult
  func requestPermission() -> Bool {
    if hasPermission { return true }
    return CGRequestScreenCaptureAccess()
  }

  @MainActor
  func refreshDisplays() async {
    guard hasPermission else {
      state = .permissionDenied
      displays = []
      return
    }
    do {
      let available = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
      content = available
      displays = available.displays.map {
        CapturableDisplay(
          id: $0.displayID,
          name: $0.width >= $0.height ? "Display \($0.displayID)" : "Portrait Display \($0.displayID)",
          width: $0.width,
          height: $0.height
        )
      }
      if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
        selectedDisplayID = displays.first(where: { $0.id == CGMainDisplayID() })?.id
          ?? displays.first?.id
      }
      state = .idle
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  @MainActor
  func start(width: Int = 1920, height: Int = 1080, fps: Int = 30) async throws {
    guard hasPermission else {
      state = .permissionDenied
      throw ScreenCaptureError.permissionDenied
    }
    await refreshDisplays()
    state = .preparing
    guard
      let selectedDisplayID,
      let display = content?.displays.first(where: { $0.displayID == selectedDisplayID })
    else {
      state = .failed("No display is available for capture.")
      throw ScreenCaptureError.displayUnavailable
    }

    await stop()

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    let target = Self.fittedSize(
      source: CGSize(width: display.width, height: display.height),
      maximum: CGSize(width: width, height: height)
    )
    configuration.width = Int(target.width)
    configuration.height = Int(target.height)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    configuration.queueDepth = 5
    configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    configuration.showsCursor = true
    configuration.capturesAudio = false

    let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
    stream = newStream
    try await newStream.startCapture()
    state = .capturing
  }

  @MainActor
  func stop() async {
    guard let stream else {
      if state == .capturing { state = .idle }
      return
    }
    self.stream = nil
    try? await stream.stopCapture()
    if state == .capturing || state == .preparing { state = .idle }
  }

  nonisolated func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard
      outputType == .screen,
      sampleBuffer.isValid,
      let imageBuffer = sampleBuffer.imageBuffer,
      Self.isCompleteFrame(sampleBuffer)
    else { return }
    frameHandler?(imageBuffer, sampleBuffer.presentationTimeStamp)
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    Task { @MainActor [weak self] in
      self?.stream = nil
      self?.state = .failed(error.localizedDescription)
    }
  }

  nonisolated static func fittedSize(source: CGSize, maximum: CGSize) -> CGSize {
    guard source.width > 0, source.height > 0 else { return maximum }
    let scale = min(maximum.width / source.width, maximum.height / source.height, 1)
    return CGSize(
      width: max(2, floor(source.width * scale / 2) * 2),
      height: max(2, floor(source.height * scale / 2) * 2)
    )
  }

  private nonisolated static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[SCStreamFrameInfo: Any]],
      let statusRaw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: statusRaw)
    else { return false }
    return status == .complete
  }
}

enum ScreenCaptureError: LocalizedError {
  case permissionDenied
  case displayUnavailable

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Allow Screen Recording in System Settings before sharing this Mac."
    case .displayUnavailable:
      "The selected display is no longer connected."
    }
  }
}
