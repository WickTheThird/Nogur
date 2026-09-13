//
//  ContentView.swift
//  Nogur
//
//  Created by Filip Bumbu on 13/09/2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mainContent
        }
        .frame(
            minWidth: 700,
            minHeight: 500
        )
    }
    
    private var sidebar: some View {
        List {
            Section("Devices") {
                Label("My Mac", systemImage: "laptopcomputer")
            }
            
            Section("Account") {
                Label("Profile", systemImage: "person.circle")
                Label("Settings", systemImage: "gear")
            }
        }
        .navigationSplitViewColumnWidth(
            min: 180,
            ideal: 220,
            max: 280
        )
    }
    
    private var mainContent: some View {
        VStack {
            Spacer()
            
            Image(systemName: "display")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No device selected")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Select a devoce from the sidebar")
                .foregroundStyle(.secondary)
            
            Spacer()
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }
}

#Preview {
    ContentView()
}
