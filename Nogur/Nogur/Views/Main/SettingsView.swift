//
//  SettingsView.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @EnvironmentObject private var screenCapture: ScreenCaptureService
  private var versionText: String {
    let version =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "1.0"

    let build =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
      ) as? String ?? "1"

    return "Version \(version) (\(build))"
  }

  var body: some View {
    DashboardPage {
      VStack(alignment: .leading, spacing: 24) {
        DashboardHeader(
          title: "Settings",
          subtitle: "Review how this Nogur app is configured.",
          systemImage: "gearshape"
        )

        GlassPanel {
          VStack(alignment: .leading, spacing: 18) {
            Text("Connection")
              .font(.headline)

            AccountDetailRow(
              systemImage: "network",
              title: "Server",
              value: "api.bumbuindustries.com",
              supportingText: "Nogur uses an encrypted HTTPS connection for account requests."
            )

            Divider()

            AccountDetailRow(
              systemImage: "key.horizontal",
              title: "Credentials",
              value: "Stored in Keychain",
              supportingText: "Authentication tokens are kept out of app preferences."
            )
          }
        }

        GlassPanel {
          VStack(alignment: .leading, spacing: 18) {
            Text("Remote access permissions")
              .font(.headline)

            permissionRow(
              title: "Screen Recording",
              detail: "Required only when this Mac shares a display.",
              granted: screenCapture.hasPermission,
              action: {
                _ = screenCapture.requestPermission()
                Task { await screenCapture.refreshDisplays() }
              }
            )

            Divider()

            permissionRow(
              title: "Accessibility",
              detail: "Required only when you approve remote keyboard or pointer control.",
              granted: coordinator.accessibilityAllowed,
              action: { _ = coordinator.requestAccessibilityPermission() }
            )

            if !screenCapture.displays.isEmpty {
              Divider()
              Picker("Display to share", selection: $screenCapture.selectedDisplayID) {
                ForEach(screenCapture.displays) { display in
                  Text("\(display.name) · \(display.width) × \(display.height)")
                    .tag(Optional(display.id))
                }
              }
            }
          }
        }

        GlassPanel {
          VStack(alignment: .leading, spacing: 18) {
            Text("Application")
              .font(.headline)

            AccountDetailRow(
              systemImage: "circle.lefthalf.filled",
              title: "Appearance",
              value: "Follow system",
              supportingText: "Nogur automatically matches your Mac's light or dark appearance."
            )

            Divider()

            AccountDetailRow(
              systemImage: "info.circle",
              title: "Nogur",
              value: versionText,
              supportingText: "More preferences will be added alongside device support."
            )
          }
        }
      }
    }
    .navigationTitle("Settings")
    .task {
      await screenCapture.refreshDisplays()
    }
  }

  private func permissionRow(
    title: String,
    detail: String,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 14) {
      Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(granted ? .green : .orange)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.body.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if !granted {
        Button("Allow", action: action)
      }
    }
  }
}

#Preview {
  let coordinator = AppCoordinator()
  SettingsView()
    .environmentObject(coordinator)
    .environmentObject(coordinator.screenCapture)
    .frame(width: 900, height: 650)
}
