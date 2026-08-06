//
//  ContentView.swift
//  DualCast
//
//  Main control surface: one row per display with enable toggle, editable NDI
//  source name, live preview, throughput stats, receiver count, and
//  LIVE/PREVIEW tally badges.
//

import SwiftUI

struct ContentView: View {
    @Environment(StreamManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager

        VStack(alignment: .leading, spacing: 16) {
            header

            if !manager.ndiAvailable {
                banner(
                    text: "NDI library unavailable. Install with: brew install --cask libndi",
                    color: .red
                )
            } else if !manager.permissionGranted {
                permissionBanner
            }

            if let error = manager.globalError, manager.ndiAvailable, manager.permissionGranted {
                banner(text: error, color: .orange)
            }

            ForEach($manager.displays) { $display in
                DisplayRowView(
                    display: $display,
                    preview: manager.previews[display.id],
                    carriesAudio: manager.audioDisplayID == display.id,
                    audioLevel: manager.audioLevels[display.id] ?? 0,
                    onToggleAudio: {
                        Task { await manager.setAudioDisplay(display.id) }
                    }
                ) {
                    Task {
                        if display.isStreaming {
                            await manager.stop(id: display.id)
                        } else {
                            await manager.start(id: display.id)
                        }
                    }
                }
            }

            if manager.displays.isEmpty, manager.permissionGranted, manager.ndiAvailable {
                ContentUnavailableView(
                    "No Displays Found",
                    systemImage: "display.2",
                    description: Text("Grant screen recording permission, then refresh.")
                )
            }

            Divider()
            controls
            footer
        }
        .padding(20)
        .frame(minWidth: 620)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("DualCast").font(.title2).bold()
                Text("Each display is a separate NDI source on the network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isAnyStreaming {
                Label("\(manager.streamingCount) live", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            }
        }
    }

    private var permissionBanner: some View {
        HStack {
            Label("Screen recording permission required", systemImage: "exclamationmark.shield")
                .foregroundStyle(.white)
            Spacer()
            Button("Grant Access…") {
                Task { await manager.requestPermission() }
            }
            Button("Open Settings") {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
    }

    private func banner(text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color))
    }

    private var controls: some View {
        HStack {
            Button("Start All") {
                Task { await manager.startAll() }
            }
            .controlSize(.large)
            .disabled(!manager.permissionGranted || !manager.ndiAvailable)

            Button("Stop All") {
                Task { await manager.stopAll() }
            }
            .controlSize(.large)
            .disabled(!manager.isAnyStreaming)

            Spacer()

            Button {
                Task { await manager.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("NDI \(manager.ndiVersion)")
            Text("·")
            Text("Receivers see sources as “\(ProcessInfo.processInfo.hostName) (name)”")
            Spacer()
            Text("1440p30 per display")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Display row

private struct DisplayRowView: View {
    @Binding var display: StreamManager.DisplayItem
    let preview: CGImage?
    let carriesAudio: Bool
    let audioLevel: Float
    let onToggleAudio: () -> Void
    let onToggleStreaming: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            previewView

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle(isOn: $display.isEnabled) {
                        Text(display.name).font(.headline)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(display.isStreaming)

                    Button(action: onToggleAudio) {
                        Image(systemName: carriesAudio ? "speaker.wave.2.fill" : "speaker.slash")
                            .foregroundStyle(carriesAudio ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(carriesAudio
                          ? "System audio rides this stream — tap to move it off"
                          : "Attach system audio to this stream")

                    Spacer()

                    if display.stats.onProgram {
                        badge("LIVE", .red)
                    } else if display.stats.onPreview {
                        badge("PREVIEW", .green)
                    }
                }

                Text("\(display.nativeWidth)×\(display.nativeHeight) → \(display.stats.outputWidth)×\(display.stats.outputHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("NDI name:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Source name", text: $display.ndiName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(display.isStreaming)
                }

                HStack(spacing: 12) {
                    Circle()
                        .fill(display.isStreaming ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 8, height: 8)

                    if display.isStreaming {
                        Text(String(format: "%.0f fps", display.stats.framesPerSecond))
                        Text("·")
                        Text("\(display.stats.framesSent) frames")
                        Text("·")
                        Text(display.stats.connections == 1
                             ? "1 receiver"
                             : "\(display.stats.connections) receivers")
                    } else {
                        Text("Not streaming").foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(display.isStreaming ? "Stop" : "Start", action: onToggleStreaming)
                        .disabled(!display.isEnabled && !display.isStreaming)
                }
                .font(.callout)

                if carriesAudio {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule()
                                    .fill(audioLevel > 0.8 ? Color.red : (audioLevel > 0.5 ? Color.yellow : Color.green))
                                    .frame(width: max(2, geometry.size.width * CGFloat(min(audioLevel, 1))))
                            }
                        }
                        .frame(height: 6)
                        Text("48 kHz stereo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = display.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(display.stats.onProgram ? Color.red : Color.clear, lineWidth: 2)
        )
    }

    private var previewView: some View {
        Group {
            if let preview {
                Image(decorative: preview, scale: 1.0)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.6))
                    Image(systemName: display.isStreaming ? "dot.radiowaves.left.and.right" : "display")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .frame(width: 160)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
