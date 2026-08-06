//
//  DualCastApp.swift
//  DualCast
//
//  App entry point. Streams each connected display as an independent NDI
//  source so a remote streaming Mac (running DualCast Switcher, OBS with
//  obs-ndi, Ecamm Live, or any NDI receiver) can receive them.
//

import SwiftUI

@main
struct DualCastApp: App {
    @State private var manager = StreamManager()

    var body: some Scene {
        WindowGroup("DualCast") {
            ContentView()
                .environment(manager)
                .task {
                    await manager.refresh()
                }
        }
        .defaultSize(width: 680, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appVisibility) {
                Button("Refresh Displays") {
                    Task { await manager.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
