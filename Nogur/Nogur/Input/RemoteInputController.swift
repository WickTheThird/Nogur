import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct NormalizedPoint: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
}

enum RemoteInputEvent: Codable, Equatable, Sendable {
  case pointerMove(NormalizedPoint)
  case mouseButton(button: Int, down: Bool, point: NormalizedPoint)
  case scroll(deltaX: Double, deltaY: Double)
  case key(code: UInt16, down: Bool, flags: UInt64)
}

enum CoordinateMapper {
  static func aspectFitRect(for size: CGSize, in bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
      return bounds
    }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
      x: bounds.midX - fitted.width / 2,
      y: bounds.midY - fitted.height / 2,
      width: fitted.width,
      height: fitted.height
    )
  }

  static func point(_ normalized: NormalizedPoint, in frame: CGRect) -> CGPoint {
    CGPoint(
      x: frame.minX + min(max(normalized.x, 0), 1) * frame.width,
      y: frame.minY + min(max(normalized.y, 0), 1) * frame.height
    )
  }

  static func normalizedPoint(
    _ point: CGPoint,
    contentRect: CGRect
  ) -> NormalizedPoint? {
    guard contentRect.width > 0, contentRect.height > 0, contentRect.contains(point) else {
      return nil
    }
    return NormalizedPoint(
      x: (point.x - contentRect.minX) / contentRect.width,
      y: (point.y - contentRect.minY) / contentRect.height
    )
  }
}

struct HeldInputState: Equatable, Sendable {
  private(set) var keys: Set<UInt16> = []
  private(set) var buttons: Set<Int> = []

  mutating func updateKey(_ code: UInt16, down: Bool) {
    if down { keys.insert(code) } else { keys.remove(code) }
  }

  mutating func updateButton(_ button: Int, down: Bool) {
    if down { buttons.insert(button) } else { buttons.remove(button) }
  }

  mutating func drain() -> (keys: Set<UInt16>, buttons: Set<Int>) {
    defer {
      keys.removeAll()
      buttons.removeAll()
    }
    return (keys, buttons)
  }
}

final class RemoteInputController: @unchecked Sendable {
  private let lock = NSLock()
  private var heldInput = HeldInputState()
  private var active = false
  private var approved: Set<SessionCapability> = []
  private var displayFrame = CGRect.zero
  private var emergencyMonitor: Any?
  var emergencyStop: (@Sendable () -> Void)?

  var accessibilityAllowed: Bool {
    AXIsProcessTrusted()
  }

  @discardableResult
  func requestAccessibilityPermission() -> Bool {
    let options = [
      kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  func begin(capabilities: [SessionCapability], displayID: CGDirectDisplayID) {
    lock.lock()
    approved = Set(capabilities)
    displayFrame = CGDisplayBounds(displayID)
    active = true
    lock.unlock()
    installEmergencyStop()
  }

  func handle(_ event: RemoteInputEvent) {
    lock.lock()
    guard active, accessibilityAllowed else {
      lock.unlock()
      return
    }
    let capabilities = approved
    let frame = displayFrame
    lock.unlock()

    switch event {
    case .pointerMove(let point):
      guard capabilities.contains(.inputPointer) else { return }
      postMouse(type: .mouseMoved, point: CoordinateMapper.point(point, in: frame), button: .left)
    case .mouseButton(let rawButton, let down, let point):
      guard capabilities.contains(.inputPointer) else { return }
      let button: CGMouseButton = switch rawButton {
      case 1: .right
      case 2: .center
      default: .left
      }
      let type: CGEventType
      switch button {
      case .right: type = down ? .rightMouseDown : .rightMouseUp
      case .center: type = down ? .otherMouseDown : .otherMouseUp
      default: type = down ? .leftMouseDown : .leftMouseUp
      }
      updateButton(rawButton, down: down)
      postMouse(type: type, point: CoordinateMapper.point(point, in: frame), button: button)
    case .scroll(let deltaX, let deltaY):
      guard capabilities.contains(.inputScroll) else { return }
      CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 2,
        wheel1: Int32(deltaY),
        wheel2: Int32(deltaX),
        wheel3: 0
      )?.post(tap: .cghidEventTap)
    case .key(let code, let down, let rawFlags):
      guard capabilities.contains(.inputKeyboard) else { return }
      updateKey(code, down: down)
      let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      event?.flags = CGEventFlags(rawValue: rawFlags)
      event?.post(tap: .cghidEventTap)
    }
  }

  func end() {
    lock.lock()
    let held = heldInput.drain()
    approved.removeAll()
    active = false
    lock.unlock()

    for code in held.keys {
      CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?
        .post(tap: .cghidEventTap)
    }
    let cursor = CGEvent(source: nil)?.location ?? .zero
    for button in held.buttons {
      let mouseButton: CGMouseButton = switch button {
      case 1: .right
      case 2: .center
      default: .left
      }
      let type: CGEventType = switch mouseButton {
      case .right: .rightMouseUp
      case .center: .otherMouseUp
      default: .leftMouseUp
      }
      postMouse(type: type, point: cursor, button: mouseButton)
    }
    if let emergencyMonitor {
      NSEvent.removeMonitor(emergencyMonitor)
      self.emergencyMonitor = nil
    }
  }

  private func installEmergencyStop() {
    guard emergencyMonitor == nil else { return }
    emergencyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      let required: NSEvent.ModifierFlags = [.command, .option]
      if event.keyCode == 53 && event.modifierFlags.intersection(required) == required {
        self?.emergencyStop?()
        return nil
      }
      return event
    }
  }

  private func updateKey(_ code: UInt16, down: Bool) {
    lock.lock()
    heldInput.updateKey(code, down: down)
    lock.unlock()
  }

  private func updateButton(_ button: Int, down: Bool) {
    lock.lock()
    heldInput.updateButton(button, down: down)
    lock.unlock()
  }

  private func postMouse(type: CGEventType, point: CGPoint, button: CGMouseButton) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
      .post(tap: .cghidEventTap)
  }
}
