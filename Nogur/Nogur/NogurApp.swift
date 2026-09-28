//
//  NogurApp.swift
//  Nogur
//
//  Created by Filip Bumbu on 13/09/2026.
//

import SwiftUI

@main
struct NogurApp: App {
  @StateObject private var authViewModel = AuthViewModel()

  var body: some Scene {
    WindowGroup {
      Group {
        if authViewModel.isAuthenticated {
          ContentView()
            .environmentObject(authViewModel)
        } else {
          AuthView(viewModel: authViewModel)
        }
      }
    }
    .defaultSize(width: 900, height: 560)
    .windowResizability(.contentMinSize)
  }
}
