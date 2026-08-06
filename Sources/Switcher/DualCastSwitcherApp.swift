//
//  DualCastSwitcherApp.swift
//  DualCast Switcher
//
//  NDI-to-NDI relay: receives the two DualCast display streams and
//  re-broadcasts the selected one as a single NDI source ("DualCast
//  Active Display") for Ecamm Live. Switch with ⌃⌥⌘1 / ⌃⌥⌘2 / ⌃⌥⌘3
//  (Stream Deck "Hotkey" actions trigger these globally).
//

import SwiftUI

@main
struct DualCastSwitcherApp: App {
    @State private var manager = SwitcherManager()

    var body: some Scene {
        WindowGroup("DualCast Switcher") {
            SwitcherContentView()
                .environment(manager)
                .task {
                    await manager.bootstrap()
                }
        }
        .defaultSize(width: 780, height: 560)
        .windowResizability(.contentMinSize)
    }
}
