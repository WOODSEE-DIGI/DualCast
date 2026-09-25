//
//  StreamManager.swift
//  DualCast
//
//  Owns display enumeration, screen-recording permission state, and one
//  DisplayCapture pipeline per streamed display. All UI-facing state lives
//  here on the main actor.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit

/// Sendable box for the list of DualCast's own windows excluded from capture.
/// SCWindow is an Objective-C class without Sendable conformance; the list is
/// only read synchronously while building the capture filter, never retained.
struct WindowExclusionList: @unchecked Sendable {
    let windows: [SCWindow]
}

@MainActor @Observable
final class StreamManager {
    struct DisplayItem: Identifiable, Sendable {
        let id: CGDirectDisplayID
        var name: String
        var nativeWidth: Int
        var nativeHeight: Int
        var isEnabled: Bool = true
        var ndiName: String
        var isStreaming: Bool = false
        var stats: CaptureStats = CaptureStats()
        var error: String? = nil
    }

    var displays: [DisplayItem] = []
    var previews: [CGDirectDisplayID: CGImage] = [:]
    /// Latest audio peak per display (0...1), ~10 Hz while audio flows.
    private(set) var audioLevels: [CGDirectDisplayID: Float] = [:]

    struct CameraItem: Identifiable, Sendable {
        let id: String
        var name: String
        var isEnabled: Bool = true
        var ndiName: String
        var isStreaming: Bool = false
        var stats: CaptureStats = CaptureStats()
        var error: String? = nil
    }

    var cameras: [CameraItem] = []
    var cameraPreviews: [String: CGImage] = [:]

    private(set) var permissionGranted = false
    private(set) var cameraPermissionGranted = false
    private(set) var ndiAvailable = false
    private(set) var ndiVersion = ""
    var globalError: String? = nil

    /// Which display's stream carries system audio (macOS has no per-display
    /// audio — it can ride exactly one stream). Persisted across launches.
    var audioDisplayID: CGDirectDisplayID? {
        didSet {
            let defaults = UserDefaults.standard
            if let audioDisplayID {
                defaults.set(Int64(bitPattern: UInt64(audioDisplayID)), forKey: Self.audioDisplayDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.audioDisplayDefaultsKey)
            }
        }
    }

    private static let audioDisplayDefaultsKey = "dualcast.audioDisplayID"

    /// SCDisplay lookup for the current shareable content snapshot.
    private var scDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    /// DualCast's own windows, excluded from capture to avoid mirror feedback.
    private var ownWindows: [SCWindow] = []
    private var pipelines: [CGDirectDisplayID: DisplayCapture] = [:]
    private var cameraPipelines: [String: CameraCapture] = [:]
    private let cameraDiscovery = CameraDiscovery()
    private var tallyTask: Task<Void, Never>?

    var isAnyStreaming: Bool {
        displays.contains { $0.isStreaming } || cameras.contains { $0.isStreaming }
    }

    var streamingCount: Int {
        displays.filter { $0.isStreaming }.count + cameras.filter { $0.isStreaming }.count
    }

    // MARK: - Refresh

    /// Re-checks NDI, screen-recording permission, camera permission, and the display/camera lists.
    func refresh() async {
        ndiAvailable = NDILibrary.isAvailable
        ndiVersion = NDILibrary.version
        permissionGranted = CGPreflightScreenCaptureAccess()
        cameraPermissionGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

        refreshCameras()

        guard ndiAvailable else {
            globalError = "libndi is not available. Install it with: brew install --cask libndi"
            return
        }
        guard permissionGranted else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let names = displayNamesByID()
            let ownBundleID = Bundle.main.bundleIdentifier

            scDisplays = Dictionary(
                uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) }
            )
            ownWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == ownBundleID
            }
            globalError = nil

            displays = content.displays.map { display in
                let name = names[display.displayID] ?? "Display \(display.displayID)"
                var item = DisplayItem(
                    id: display.displayID,
                    name: name,
                    nativeWidth: display.width,
                    nativeHeight: display.height,
                    ndiName: "DualCast \(name)"
                )
                // Preserve streaming state and user edits across refreshes.
                if let existing = displays.first(where: { $0.id == display.displayID }) {
                    item.isEnabled = existing.isEnabled
                    item.ndiName = existing.ndiName
                    item.isStreaming = existing.isStreaming
                    item.stats = existing.stats
                    item.error = existing.error
                }
                return item
            }.sorted { $0.name < $1.name }

            // Restore / default the audio-carrying display (main display first).
            let stored = UserDefaults.standard.object(forKey: Self.audioDisplayDefaultsKey) as? Int64
            let storedID = stored.map { CGDirectDisplayID(UInt64(bitPattern: $0)) }
            if let storedID, displays.contains(where: { $0.id == storedID }) {
                audioDisplayID = storedID
            } else {
                let mainID = NSScreen.main?.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID
                audioDisplayID = mainID ?? displays.first?.id
            }
        } catch {
            globalError = "Failed to enumerate displays: \(error.localizedDescription)"
        }
    }

    /// Opens the system screen-recording consent flow, then re-checks.
    func requestPermission() async {
        _ = CGRequestScreenCaptureAccess()
        await refresh()
    }

    /// Opens the system camera consent flow, then re-checks.
    func requestCameraPermission() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        await refresh()
    }

    // MARK: - Camera discovery

    func refreshCameras() {
        cameraDiscovery.refresh()
        let discovered = cameraDiscovery.cameras

        cameras = discovered.map { source in
            var item = CameraItem(
                id: source.id,
                name: source.localizedName,
                ndiName: "DualCast \(source.localizedName)"
            )
            if let existing = cameras.first(where: { $0.id == source.id }) {
                item.isEnabled = existing.isEnabled
                item.ndiName = existing.ndiName
                item.isStreaming = existing.isStreaming
                item.stats = existing.stats
                item.error = existing.error
            }
            return item
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Start / stop

    func startAll() async {
        for display in displays where display.isEnabled {
            await start(id: display.id)
        }
    }

    func stopAll() async {
        for id in pipelines.keys {
            await stop(id: id)
        }
        for id in cameraPipelines.keys {
            await stopCamera(id: id)
        }
    }

    func start(id: CGDirectDisplayID) async {
        guard pipelines[id] == nil,
              let scDisplay = scDisplays[id],
              let index = displays.firstIndex(where: { $0.id == id }) else { return }

        let pipeline = DisplayCapture(display: scDisplay)
        pipelines[id] = pipeline
        displays[index].error = nil

        pipeline.onStats = { [weak self] stats in
            self?.applyStats(stats, for: id)
        }
        pipeline.onPreview = { [weak self] image in
            self?.previews[id] = image
        }
        pipeline.onError = { [weak self] message in
            self?.applyError(message, for: id)
        }
        pipeline.onAudioLevel = { [weak self] level in
            self?.audioLevels[id] = level
        }

        do {
            let configuration = DisplayCapture.Configuration(
                ndiSourceName: displays[index].ndiName,
                capturesSystemAudio: id == audioDisplayID
            )
            try await pipeline.start(
                display: scDisplay,
                excludingWindows: WindowExclusionList(windows: ownWindows),
                configuration: configuration
            )
            displays[index].isStreaming = true
            startTallyPollingIfNeeded()
        } catch {
            displays[index].error = error.localizedDescription
            pipelines[id] = nil
        }
    }

    func stop(id: CGDirectDisplayID) async {
        guard let pipeline = pipelines.removeValue(forKey: id) else { return }
        await pipeline.stop()
        audioLevels[id] = 0
        if let index = displays.firstIndex(where: { $0.id == id }) {
            displays[index].isStreaming = false
            displays[index].stats.isStreaming = false
            displays[index].stats.framesPerSecond = 0
            displays[index].stats.connections = 0
            displays[index].stats.onProgram = false
            displays[index].stats.onPreview = false
        }
        if pipelines.isEmpty {
            tallyTask?.cancel()
            tallyTask = nil
        }
    }

    // MARK: - Camera start / stop

    func startCamera(id: String) async {
        guard cameraPipelines[id] == nil,
              let index = cameras.firstIndex(where: { $0.id == id }),
              let device = cameraDiscovery.cameras.first(where: { $0.id == id })?.underlyingDevice() else { return }

        let pipeline = CameraCapture(device: device)
        cameraPipelines[id] = pipeline
        cameras[index].error = nil

        pipeline.onStatus = { [weak self] stats in
            self?.applyCameraStats(stats, for: id)
        }
        pipeline.onPreview = { [weak self] image in
            self?.cameraPreviews[id] = image
        }
        pipeline.onError = { [weak self] message in
            self?.applyCameraError(message, for: id)
        }

        do {
            try await pipeline.start(configuration: CameraCapture.Configuration(
                ndiSourceName: cameras[index].ndiName
            ))
            cameras[index].isStreaming = true
            startTallyPollingIfNeeded()
        } catch {
            cameras[index].error = error.localizedDescription
            cameraPipelines[id] = nil
        }
    }

    func stopCamera(id: String) async {
        guard let pipeline = cameraPipelines.removeValue(forKey: id) else { return }
        await pipeline.stop()
        cameraPreviews[id] = nil
        if let index = cameras.firstIndex(where: { $0.id == id }) {
            cameras[index].isStreaming = false
            cameras[index].stats.isStreaming = false
            cameras[index].stats.framesPerSecond = 0
            cameras[index].stats.connections = 0
        }
        if pipelines.isEmpty && cameraPipelines.isEmpty {
            tallyTask?.cancel()
            tallyTask = nil
        }
    }

    /// Moves the audio-carrying stream to another display. If either the old
    /// or new audio display is currently streaming, its pipeline is restarted
    /// so the change applies immediately.
    func setAudioDisplay(_ id: CGDirectDisplayID) async {
        guard id != audioDisplayID else { return }
        let previous = audioDisplayID
        audioDisplayID = id

        for affected in [previous, id].compactMap({ $0 }) {
            guard pipelines[affected] != nil else { continue }
            await stop(id: affected)
            await start(id: affected)
        }
    }

    // MARK: - Pipeline callbacks

    private func applyStats(_ stats: CaptureStats, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        var updated = stats
        updated.connections = displays[index].stats.connections
        updated.onProgram = displays[index].stats.onProgram
        updated.onPreview = displays[index].stats.onPreview
        displays[index].stats = updated
    }

    private func applyError(_ message: String, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].error = message
        displays[index].isStreaming = false
        pipelines.removeValue(forKey: id)
    }

    private func applyCameraStats(_ stats: CaptureStats, for id: String) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
        var updated = stats
        updated.connections = cameras[index].stats.connections
        updated.onProgram = cameras[index].stats.onProgram
        updated.onPreview = cameras[index].stats.onPreview
        cameras[index].stats = updated
    }

    private func applyCameraError(_ message: String, for id: String) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
        cameras[index].error = message
        cameras[index].isStreaming = false
        cameraPipelines.removeValue(forKey: id)
    }

    // MARK: - Tally / receiver polling

    /// Polls each sender's receiver count and tally state every 2 seconds
    /// so the UI can show "1 receiver" and LIVE/PREVIEW badges.
    private func startTallyPollingIfNeeded() {
        guard tallyTask == nil else { return }
        tallyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let displaySnapshot = self.pipelines
                for (id, pipeline) in displaySnapshot {
                    let status = await Task.detached {
                        pipeline.pollStatus()
                    }.value
                    self.applyStatus(status, for: id)
                }
                let cameraSnapshot = self.cameraPipelines
                for (id, pipeline) in cameraSnapshot {
                    let status = await Task.detached {
                        (pipeline.connectionCount, pipeline.tally)
                    }.value
                    self.applyCameraStatus(status, for: id)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func applyCameraStatus(_ status: (connections: Int, tally: NDISender.Tally), for id: String) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
        cameras[index].stats.connections = status.connections
        cameras[index].stats.onProgram = status.tally.onProgram
        cameras[index].stats.onPreview = status.tally.onPreview
    }

    private func applyStatus(_ status: (connections: Int, tally: NDISender.Tally),
                             for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].stats.connections = status.connections
        displays[index].stats.onProgram = status.tally.onProgram
        displays[index].stats.onPreview = status.tally.onPreview
    }

    // MARK: - Display naming

    /// Maps CGDirectDisplayID to the human-readable NSScreen localizedName
    /// (e.g. "Studio Display", "BenQ PD3200U").
    private func displayNamesByID() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { continue }
            result[number] = screen.localizedName
        }
        return result
    }
}
