//
//  SwitcherContentView.swift
//  DualCast Switcher
//
//  Control surface: two input slots with live previews and ON AIR state,
//  source pickers, output (relay) status, and hotkey/Stream Deck hints.
//

import SwiftUI

struct SwitcherContentView: View {
    @Environment(SwitcherManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !manager.ndiAvailable {
                Label("NDI library unavailable.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.red))
            }
            if let error = manager.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.orange))
            }

            HStack(spacing: 14) {
                SlotCardView(
                    slot: 0,
                    title: "Slot A",
                    hotkeyLabel: SwitcherManager.hotkeyLabels[0],
                    manager: manager
                )
                SlotCardView(
                    slot: 1,
                    title: "Slot B",
                    hotkeyLabel: SwitcherManager.hotkeyLabels[1],
                    manager: manager
                )
            }

            controls
            Divider()
            footer
        }
        .padding(18)
        .frame(minWidth: 720)
    }

    private var header: some View {
        HStack {
            Image(systemName: "rectangle.2.swap")
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("DualCast Switcher").font(.title2).bold()
                Text("Relays the active input as one NDI source for Ecamm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isRunning {
                if manager.outputOnProgram {
                    badge("LIVE IN ECAMM", .red)
                } else if manager.outputOnPreview {
                    badge("ECAMM PREVIEW", .green)
                }
                Label(
                    "\(manager.outputReceivers) receiver\(manager.outputReceivers == 1 ? "" : "s")",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                .foregroundStyle(manager.outputReceivers > 0 ? .green : .secondary)
            }
        }
    }

    private var controls: some View {
        HStack {
            Button {
                manager.toggleSlot()
            } label: {
                Label("Toggle (\(SwitcherManager.toggleHotkeyLabel))", systemImage: "arrow.left.arrow.right")
            }
            .disabled(!manager.isRunning)

            Spacer()

            Text("Output NDI name:")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Output name", text: Binding(
                get: { manager.outputName },
                set: { manager.outputName = $0 }
            ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .disabled(manager.isRunning)

            if manager.isRunning {
                Button("Stop", role: .destructive) {
                    Task { await manager.stop() }
                }
            } else {
                Button("Start") {
                    Task { await manager.start() }
                }
                .disabled(!manager.ndiAvailable)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stream Deck setup: add “Hotkey” actions ⌃⌥⌘1 (Slot A) and ⌃⌥⌘2 (Slot B) — they work globally, no plugin needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Ecamm: add “\(manager.outputName)” as the single NDI camera; switching happens upstream here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
    }
}

// MARK: - Slot card

private struct SlotCardView: View {
    let slot: Int
    let title: String
    let hotkeyLabel: String
    @Bindable var manager: SwitcherManager

    private var isActive: Bool { manager.isRunning && manager.activeSlot == slot }
    private var selectedName: String {
        get { manager.slotSourceNames[slot] }
        nonmutating set { manager.slotSourceNames[slot] = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Text(hotkeyLabel)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.2)))
                Spacer()
                if isActive {
                    Text("ON AIR")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                        .foregroundStyle(.white)
                }
            }

            previewView

            Picker("Source", selection: Binding(get: { selectedName }, set: { selectedName = $0 })) {
                Text("Not assigned").tag("")
                ForEach(manager.discoveredSources, id: \.name) { source in
                    Text(source.shortName).tag(source.name)
                }
            }
            .labelsHidden()
            .disabled(manager.isRunning)

            HStack(spacing: 8) {
                statusDot
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select") {
                    manager.selectSlot(slot)
                }
                .disabled(!manager.isRunning || isActive)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.red : Color.clear, lineWidth: 2.5)
        )
    }

    private var previewView: some View {
        Group {
            if let image = manager.previews[slot] {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.6))
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusDot: some View {
        let color: Color = {
            guard manager.isRunning else { return .gray.opacity(0.4) }
            switch manager.slotStatuses[slot] {
            case .receiving: return .green
            case .connecting: return .yellow
            case .failed: return .red
            case .idle, nil: return .gray.opacity(0.4)
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private var statusText: String {
        if !manager.isRunning { return "Stopped" }
        let stats = manager.slotStats[slot]
        switch manager.slotStatuses[slot] {
        case .receiving:
            let fps = stats?.framesPerSecond ?? 0
            let frames = stats?.framesReceived ?? 0
            return String(format: "%.0f fps · %llu frames", fps, frames)
        case .connecting:
            return "Connecting…"
        case .failed(let message):
            return "Failed: \(message)"
        case .idle, nil:
            return "Idle"
        }
    }
}
