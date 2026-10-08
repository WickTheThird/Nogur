//
//  ContentView.swift
//  Nogur
//
//  Created by Filip Bumbu on 13/09/2026.
//

import SwiftUI

enum SidebarDestination: String, Hashable, Identifiable {
  case thisMac
  case profile
  case settings

  var id: Self {
    self
  }
}

struct ContentView: View {
  @EnvironmentObject private var authViewModel: AuthViewModel
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var selection: SidebarDestination? = .thisMac

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      selectedPage
    }
    .frame(
      minWidth: 700,
      minHeight: 500
    )
    .toolbar {
      if coordinator.hasActiveControl {
        ToolbarItem(placement: .principal) {
          Label("Remote control active", systemImage: "record.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.red.opacity(0.11), in: Capsule())
            .accessibilityIdentifier("session.controlActive")
        }
      }
      ToolbarItem {
        Button {
          coordinator.stop()
          authViewModel.signOut()
        } label: {
          Label(
            "Sign Out",
            systemImage: "rectangle.portrait.and.arrow.right"
          )
        }
        .help("Sign out of Nogur")
      }
    }
    .task {
      coordinator.start()
    }
    .onDisappear {
      coordinator.stop()
    }
  }

  private var sidebar: some View {
    List(selection: $selection) {
      Section("Devices") {
        Label("Devices", systemImage: "laptopcomputer")
          .tag(SidebarDestination.thisMac)
      }

      Section("Account") {
        Label("Profile", systemImage: "person.crop.circle")
          .tag(SidebarDestination.profile)

        Label("Settings", systemImage: "gear")
          .tag(SidebarDestination.settings)
      }
    }
    .navigationTitle("Nogur")
    .navigationSplitViewColumnWidth(
      min: 180,
      ideal: 220,
      max: 280
    )
  }

  @ViewBuilder
  private var selectedPage: some View {
    switch selection {
    case .thisMac:
      DeviceOverviewView()

    case .profile:
      ProfileView()

    case .settings:
      SettingsView()

    case nil:
      ContentUnavailableView(
        "Choose a Section",
        systemImage: "sidebar.left",
        description: Text("Select an item from the sidebar.")
      )
    }
  }
}

#Preview {
  let coordinator = AppCoordinator()
  ContentView()
    .environmentObject(AuthViewModel())
    .environmentObject(coordinator)
    .environmentObject(coordinator.webRTC)
}
