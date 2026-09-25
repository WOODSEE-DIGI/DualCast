//
//  VirtualCameraDevice.swift
//  DualCastCameraExtension
//
//  A single virtual camera device with one video stream. Initially renders a
//  test pattern; later it will be wired to an NDI receiver.
//

import CoreMediaIO
import Foundation

final class VirtualCameraDevice: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private let streamSource: VirtualCameraStreamSource

    init(localizedName: String, deviceID: UUID, legacyDeviceID: String, assignedSourceKey: String) {
        self.streamSource = VirtualCameraStreamSource(assignedSourceKey: assignedSourceKey)
        super.init()

        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: legacyDeviceID,
            source: self
        )

        do {
            try self.device.addStream(streamSource.stream)
        } catch {
            NSLog("[DualCastCameraExtension] Failed to add stream to \(localizedName): \(error)")
        }
    }

    // MARK: - CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
        return []
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        return CMIOExtensionDeviceProperties(dictionary: [:])
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
    }
}
