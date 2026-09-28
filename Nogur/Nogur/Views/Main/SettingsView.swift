//
//  SettingsView.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import SwiftUI

struct SettingsView: View {
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
  }
}

#Preview {
  SettingsView()
    .frame(width: 900, height: 650)
}
