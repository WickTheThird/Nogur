//
//  DeviceOverviewView.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import SwiftUI

struct DeviceOverviewView: View {
  var body: some View {
    DashboardPage {
      VStack(alignment: .leading, spacing: 24) {
        DashboardHeader(
          title: "This Mac",
          subtitle: "Prepare this computer for secure remote access.",
          systemImage: "laptopcomputer"
        )

        GlassPanel {
          HStack(alignment: .center, spacing: 22) {
            ZStack {
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))

              Image(systemName: "desktopcomputer")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
            }
            .frame(width: 82, height: 82)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 10) {
                Text("This Mac")
                  .font(.title2.weight(.semibold))

                StatusPill(
                  title: "Not registered",
                  systemImage: "circle.dashed",
                  color: .orange
                )
              }

              Text(
                "Device registration is the next app milestone. Once connected, this page will show availability, sessions, and connection health."
              )
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
          }
        }

        GlassPanel {
          VStack(alignment: .leading, spacing: 16) {
            Text("Next connection steps")
              .font(.headline)

            readinessRow(
              number: "1",
              title: "Create a device key",
              detail: "Generate and protect this Mac's private key in Keychain."
            )

            Divider()

            readinessRow(
              number: "2",
              title: "Register this Mac",
              detail: "Send the public key and Mac name to your Nogur account."
            )

            Divider()

            readinessRow(
              number: "3",
              title: "Connect securely",
              detail: "Keep the device online through the authenticated server connection."
            )
          }
        }
      }
    }
    .navigationTitle("This Mac")
  }

  private func readinessRow(
    number: String,
    title: String,
    detail: String
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(number)
        .font(.caption.weight(.bold))
        .foregroundStyle(.tint)
        .frame(width: 26, height: 26)
        .background(Color.accentColor.opacity(0.12), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.body.weight(.medium))

        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

#Preview {
  DeviceOverviewView()
    .frame(width: 900, height: 650)
}
