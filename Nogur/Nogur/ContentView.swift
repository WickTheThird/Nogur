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
      ToolbarItem {
        Button {
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
  }

  private var sidebar: some View {
    List(selection: $selection) {
      Section("Devices") {
        Label("This Mac", systemImage: "laptopcomputer")
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
  ContentView()
    .environmentObject(AuthViewModel())
}
