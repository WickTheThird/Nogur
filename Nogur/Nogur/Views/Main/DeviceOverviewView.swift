import SwiftUI

struct DeviceOverviewView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @EnvironmentObject private var webRTC: WebRTCManager
  @State private var sessionTarget: DeviceRecord?
  @State private var deviceToRevoke: DeviceRecord?

  private let columns = [
    GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 16)
  ]

  var body: some View {
    DashboardPage {
      VStack(alignment: .leading, spacing: 24) {
        DashboardHeader(
          title: "Devices",
          subtitle: "Your trusted Macs and secure remote sessions.",
          systemImage: "macbook.and.iphone"
        )

        if let current = coordinator.currentDevice {
          CurrentMacPanel(device: current, realtimeState: coordinator.realtimeState)
        } else {
          identityState
        }

        if let message = coordinator.errorMessage {
          GlassPanel {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }

        if let session = coordinator.displayedSession {
          SessionStatusPanel(
            session: session,
            peerName: coordinator.deviceName(
              for: session.sourceDeviceID == coordinator.currentDeviceID
                ? session.targetDeviceID
                : session.sourceDeviceID
            ),
            endAction: session.status.isTerminal
              ? nil
              : { Task { await coordinator.endCurrentSession() } }
          )
        }

        if let track = webRTC.remoteVideoTrack {
          GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
              Text("Remote display")
                .font(.headline)
              InteractiveRemoteVideoView(track: track) { event, reliable in
                try? webRTC.sendInput(event, preferReliable: reliable)
              }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Remote Mac display")
            }
          }
        }

        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text("Registered Macs")
              .font(.title3.weight(.semibold))
            Spacer()
            Button {
              Task { await coordinator.reload() }
            } label: {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
          }

          deviceList
        }
      }
    }
    .navigationTitle("Devices")
    .sheet(item: $sessionTarget) { target in
      NewSessionSheet(device: target) { capabilities in
        Task { await coordinator.createSession(targeting: target, capabilities: capabilities) }
      }
    }
    .sheet(item: incomingSessionBinding) { request in
      IncomingSessionSheet(
        session: request,
        sourceName: coordinator.deviceName(for: request.sourceDeviceID),
        accept: { capabilities in
          Task { await coordinator.accept(request, capabilities: capabilities) }
        },
        reject: {
          Task { await coordinator.reject(request) }
        }
      )
      .interactiveDismissDisabled()
    }
    .confirmationDialog(
      "Revoke this Mac?",
      isPresented: Binding(
        get: { deviceToRevoke != nil },
        set: { if !$0 { deviceToRevoke = nil } }
      ),
      presenting: deviceToRevoke
    ) { device in
      Button("Revoke \(device.name)", role: .destructive) {
        Task { await coordinator.revoke(device) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { device in
      Text("\(device.name) will lose remote access immediately.")
    }
  }

  private var incomingSessionBinding: Binding<RemoteSessionRecord?> {
    Binding(
      get: { coordinator.incomingRequest },
      set: { _ in }
    )
  }

  @ViewBuilder
  private var identityState: some View {
    switch coordinator.devicePhase {
    case .idle, .loading:
      GlassPanel {
        HStack(spacing: 14) {
          ProgressView()
          VStack(alignment: .leading, spacing: 3) {
            Text("Securing this Mac")
              .font(.headline)
            Text("Restoring its Keychain identity and verifying it with Nogur.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
    case .offline:
      StatePanel(
        title: "You are offline",
        detail: "Nogur will register this Mac when the network returns.",
        image: "wifi.slash",
        actionTitle: "Try Again"
      ) { Task { await coordinator.retryIdentity() } }
    case .failed(let message):
      StatePanel(
        title: "Could not prepare this Mac",
        detail: message,
        image: "exclamationmark.triangle",
        actionTitle: "Retry"
      ) { Task { await coordinator.retryIdentity() } }
    case .loaded:
      EmptyView()
    }
  }

  @ViewBuilder
  private var deviceList: some View {
    if coordinator.devices.isEmpty {
      switch coordinator.devicePhase {
      case .loading, .idle:
        ProgressView("Loading your devices...")
          .frame(maxWidth: .infinity, minHeight: 150)
      case .offline:
        StatePanel(
          title: "Devices unavailable offline",
          detail: "Reconnect to load the Macs registered to your account.",
          image: "wifi.slash",
          actionTitle: "Retry"
        ) { Task { await coordinator.reload() } }
      case .failed(let message):
        StatePanel(
          title: "Could not load devices",
          detail: message,
          image: "arrow.trianglehead.2.clockwise.rotate.90",
          actionTitle: "Retry"
        ) { Task { await coordinator.reload() } }
      case .loaded:
        ContentUnavailableView(
          "No Registered Macs",
          systemImage: "desktopcomputer",
          description: Text("Register Nogur on another Mac to connect to it.")
        )
        .frame(minHeight: 180)
      }
    } else {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
        ForEach(coordinator.devices) { device in
          DeviceCard(
            device: device,
            isCurrent: device.id == coordinator.currentDeviceID,
            connect: device.id == coordinator.currentDeviceID
              || device.revokedAt != nil
              || device.verifiedAt == nil
              ? nil
              : { sessionTarget = device },
            revoke: device.revokedAt == nil ? { deviceToRevoke = device } : nil
          )
        }
      }
    }
  }
}

private struct CurrentMacPanel: View {
  let device: DeviceRecord
  let realtimeState: RealtimeConnectionState

  var body: some View {
    GlassPanel {
      HStack(spacing: 18) {
        Image(systemName: "desktopcomputer")
          .font(.system(size: 30, weight: .medium))
          .foregroundStyle(.tint)
          .frame(width: 68, height: 68)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 9) {
            Text(device.name)
              .font(.title2.weight(.semibold))
            StatusPill(
              title: device.state.title,
              systemImage: device.state.systemImage,
              color: device.state.color
            )
          }
          Text("This Mac")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text(realtimeState.label)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
      }
    }
  }
}

private struct DeviceCard: View {
  let device: DeviceRecord
  let isCurrent: Bool
  let connect: (() -> Void)?
  let revoke: (() -> Void)?

  var body: some View {
    GlassPanel {
      VStack(alignment: .leading, spacing: 15) {
        HStack(alignment: .top) {
          Image(systemName: "desktopcomputer")
            .font(.title2)
            .foregroundStyle(.tint)
            .frame(width: 46, height: 46)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
          Spacer()
          StatusPill(
            title: device.state.title,
            systemImage: device.state.systemImage,
            color: device.state.color
          )
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(device.name)
            .font(.headline)
            .lineLimit(1)
          Text(isCurrent ? "This Mac" : device.lastSeenDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack {
          if let connect {
            Button("Connect", action: connect)
              .buttonStyle(.borderedProminent)
          }
          Spacer()
          if let revoke {
            Button("Revoke", role: .destructive, action: revoke)
              .buttonStyle(.borderless)
          }
        }
      }
    }
  }
}

private struct SessionStatusPanel: View {
  let session: RemoteSessionRecord
  let peerName: String
  let endAction: (() -> Void)?

  var body: some View {
    GlassPanel {
      HStack(spacing: 15) {
        Image(systemName: session.status.systemImage)
          .font(.title2)
          .foregroundStyle(session.status.color)
          .symbolEffect(.pulse, isActive: session.status == .connecting)
          .frame(width: 46, height: 46)
          .background(session.status.color.opacity(0.12), in: Circle())
        VStack(alignment: .leading, spacing: 3) {
          Text(session.status.title)
            .font(.headline)
          Text(peerName)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let endAction {
          Button("End Session", role: .destructive, action: endAction)
            .buttonStyle(.bordered)
        }
      }
    }
  }
}

private struct NewSessionSheet: View {
  @Environment(\.dismiss) private var dismiss
  let device: DeviceRecord
  let create: ([SessionCapability]) -> Void
  @State private var selected: Set<SessionCapability> = [.screenView]

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Connect to \(device.name)")
          .font(.title2.weight(.semibold))
        Text("The other Mac must explicitly approve this request.")
          .foregroundStyle(.secondary)
      }

      CapabilityPicker(selected: $selected, allowed: Set(SessionCapability.allCases))

      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Request Session") {
          create(SessionCapability.allCases.filter(selected.contains))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(selected.isEmpty)
      }
    }
    .padding(26)
    .frame(width: 430)
  }
}

private struct IncomingSessionSheet: View {
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var coordinator: AppCoordinator
  @EnvironmentObject private var screenCapture: ScreenCaptureService
  let session: RemoteSessionRecord
  let sourceName: String
  let accept: ([SessionCapability]) -> Void
  let reject: () -> Void
  @State private var selected: Set<SessionCapability>
  @State private var accessibilityGranted = false

  init(
    session: RemoteSessionRecord,
    sourceName: String,
    accept: @escaping ([SessionCapability]) -> Void,
    reject: @escaping () -> Void
  ) {
    self.session = session
    self.sourceName = sourceName
    self.accept = accept
    self.reject = reject
    _selected = State(initialValue: Set(session.requestedCapabilities))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 14) {
        Image(systemName: "rectangle.connected.to.line.below")
          .font(.title)
          .foregroundStyle(.tint)
          .frame(width: 54, height: 54)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        VStack(alignment: .leading, spacing: 3) {
          Text("Remote access request")
            .font(.title2.weight(.semibold))
          Text(sourceName)
            .foregroundStyle(.secondary)
        }
      }

      Text("Approve only the capabilities you want to allow. Nogur does not support unattended access.")
        .font(.callout)
        .foregroundStyle(.secondary)

      CapabilityPicker(selected: $selected, allowed: Set(session.requestedCapabilities))

      if selected.contains(.screenView), !screenCapture.hasPermission {
        Label(
          "Allow Screen Recording before accepting screen sharing.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)

        Button("Allow Screen Recording") {
          _ = screenCapture.requestPermission()
          Task { await screenCapture.refreshDisplays() }
        }
      }

      if requiresAccessibility, !accessibilityGranted {
        Label(
          "Allow Accessibility before accepting remote control.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)

        Button("Allow Accessibility") {
          accessibilityGranted = coordinator.requestAccessibilityPermission()
        }
      }

      HStack {
        Button("Reject", role: .destructive, action: reject)
          .buttonStyle(.bordered)
        Spacer()
        Button("Accept") {
          accept(SessionCapability.allCases.filter(selected.contains))
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          selected.isEmpty
            || (selected.contains(.screenView) && !screenCapture.hasPermission)
            || (requiresAccessibility && !accessibilityGranted)
        )
      }
    }
    .padding(26)
    .frame(width: 450)
    .onAppear {
      accessibilityGranted = coordinator.accessibilityAllowed
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        accessibilityGranted = coordinator.accessibilityAllowed
      }
    }
  }

  private var requiresAccessibility: Bool {
    !selected.isDisjoint(with: [.inputPointer, .inputKeyboard, .inputScroll])
  }
}

private struct CapabilityPicker: View {
  @Binding var selected: Set<SessionCapability>
  let allowed: Set<SessionCapability>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Capabilities")
        .font(.headline)
      ForEach(SessionCapability.allCases.filter(allowed.contains)) { capability in
        Toggle(capability.title, isOn: Binding(
          get: { selected.contains(capability) },
          set: { enabled in
            if enabled { selected.insert(capability) }
            else { selected.remove(capability) }
          }
        ))
      }
    }
  }
}

private struct StatePanel: View {
  let title: String
  let detail: String
  let image: String
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    GlassPanel {
      HStack(spacing: 14) {
        Image(systemName: image)
          .font(.title2)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.headline)
          Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button(actionTitle, action: action)
      }
    }
  }
}

private extension DeviceConnectionState {
  var title: String {
    switch self {
    case .online: "Online"
    case .offline: "Offline"
    case .unverified: "Unverified"
    case .revoked: "Revoked"
    }
  }

  var systemImage: String {
    switch self {
    case .online: "circle.fill"
    case .offline: "circle"
    case .unverified: "questionmark.circle"
    case .revoked: "xmark.circle"
    }
  }

  var color: Color {
    switch self {
    case .online: .green
    case .offline: .secondary
    case .unverified: .orange
    case .revoked: .red
    }
  }
}

private extension DeviceRecord {
  var lastSeenDescription: String {
    guard let lastSeenAt else { return "Never online" }
    return "Seen \(lastSeenAt.formatted(.relative(presentation: .named)))"
  }
}

private extension RealtimeConnectionState {
  var label: String {
    switch self {
    case .connected: "Realtime connection active"
    case .connecting: "Connecting to realtime service"
    case .disconnected: "Realtime connection offline"
    case .reconnecting(let attempt): "Reconnecting, attempt \(attempt)"
    case .stopped: "Realtime connection stopped"
    }
  }
}

private extension RemoteSessionStatus {
  var title: String {
    switch self {
    case .pending: "Waiting for approval"
    case .accepted: "Approved"
    case .connecting: "Connecting"
    case .active: "Session active"
    case .failed: "Connection failed"
    case .expired: "Request expired"
    case .ended: "Session ended"
    case .rejected: "Request rejected"
    }
  }

  var systemImage: String {
    switch self {
    case .pending: "hourglass"
    case .accepted: "checkmark.circle"
    case .connecting: "arrow.trianglehead.2.clockwise.rotate.90"
    case .active: "dot.radiowaves.left.and.right"
    case .failed: "exclamationmark.triangle"
    case .expired: "clock.badge.xmark"
    case .ended: "stop.circle"
    case .rejected: "xmark.circle"
    }
  }

  var color: Color {
    switch self {
    case .active: .green
    case .failed, .rejected: .red
    case .expired, .ended: .secondary
    default: .orange
    }
  }
}
