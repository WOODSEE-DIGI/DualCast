//
//  CameraDiscovery.swift
//  DualCast
//
//  Enumerates AVCaptureDevice video cameras (FaceTime, USB webcams, etc.)
//  and publishes the list. Excludes the Continuity Camera "virtual" devices
//  that macOS exposes for iPhone mirroring by default, but keeps physical
//  cameras and built-in FaceTime.
//

import AVFoundation
import Foundation

/// A discoverable camera device.
struct CameraSource: Identifiable, Hashable, Sendable {
    let id: String
    let localizedName: String
    let position: AVCaptureDevice.Position
    let deviceType: AVCaptureDevice.DeviceType

    init(device: AVCaptureDevice) {
        self.id = device.uniqueID
        self.localizedName = device.localizedName
        self.position = device.position
        self.deviceType = device.deviceType
    }

    func underlyingDevice() -> AVCaptureDevice? {
        return AVCaptureDevice(uniqueID: id)
    }
}

/// Discovers and monitors connected cameras.
@MainActor
final class CameraDiscovery: ObservableObject {
    @Published private(set) var cameras: [CameraSource] = []

    private let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [
            .builtInWideAngleCamera,
            .external
        ],
        mediaType: .video,
        position: .unspecified
    )

    func refresh() {
        cameras = discoverySession.devices
            .filter { !isContinuityCamera($0) }
            .map(CameraSource.init)
            .sorted { $0.localizedName < $1.localizedName }
    }

    private func isContinuityCamera(_ device: AVCaptureDevice) -> Bool {
        // Continuity Camera devices have a distinctive manufacturer string.
        let continuityManufacturers = ["Apple Inc.", "Apple"]
        if continuityManufacturers.contains(device.manufacturer),
           device.deviceType == .external {
            return true
        }
        // Also exclude devices whose name contains "iPhone" or "iPad".
        let lower = device.localizedName.lowercased()
        return lower.contains("iphone") || lower.contains("ipad")
    }
}
