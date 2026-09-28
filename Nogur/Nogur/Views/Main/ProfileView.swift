//
//  ProfileView.swift
//  Nogur
//
//  Created by Filip Bumbu on 28/09/2026.
//

import SwiftUI

struct ProfileView: View {
  @EnvironmentObject private var authViewModel: AuthViewModel

  private var emailAddress: String {
    authViewModel.currentEmail ?? "Email unavailable"
  }

  private var emailSupportingText: String {
    if authViewModel.currentEmail == nil {
      return "Sign out and sign in again to remember your address on this Mac."
    }

    return "Remembered securely on this Mac until server profiles are available."
  }

  private var avatarLetter: String {
    guard let first = authViewModel.currentEmail?.first else {
      return "N"
    }

    return String(first).uppercased()
  }

  var body: some View {
    DashboardPage {
      VStack(alignment: .leading, spacing: 24) {
        DashboardHeader(
          title: "Profile",
          subtitle: "Review your account and security details.",
          systemImage: "person.crop.circle"
        )

        GlassPanel {
          HStack(spacing: 18) {
            ZStack {
              Circle()
                .fill(
                  LinearGradient(
                    colors: [
                      Color.accentColor,
                      Color.purple.opacity(0.72),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                )

              Text(avatarLetter)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
              Text(emailAddress)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

              Text("Nogur account")
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(
              title: "Signed in",
              systemImage: "checkmark.circle.fill",
              color: .green
            )
          }
        }

        GlassPanel {
          VStack(alignment: .leading, spacing: 18) {
            Text("Account details")
              .font(.headline)

            AccountDetailRow(
              systemImage: "envelope",
              title: "Email address",
              value: emailAddress,
              supportingText: emailSupportingText
            )

            Divider()

            AccountDetailRow(
              systemImage: "key",
              title: "Password",
              value: "••••••••••••",
              supportingText: "Nogur never saves your password on this Mac."
            )

            Divider()

            AccountDetailRow(
              systemImage: "lock.shield",
              title: "Session storage",
              value: "macOS Keychain",
              supportingText: "Your access and refresh tokens are protected by the system Keychain."
            )
          }
        }

        GlassPanel {
          VStack(alignment: .leading, spacing: 14) {
            Label(
              "Account editing is coming later",
              systemImage: "server.rack"
            )
            .font(.headline)

            Text(
              "Changing your email or password needs profile endpoints on the server. These actions will become available when that work is added."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
              Button("Change Email") {}
                .disabled(true)

              Button("Change Password") {}
                .disabled(true)
            }
            .help("Requires a server update")
          }
        }
      }
    }
    .navigationTitle("Profile")
  }
}

#Preview {
  ProfileView()
    .environmentObject(AuthViewModel())
    .frame(width: 900, height: 650)
}
