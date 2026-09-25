//
//  CameraExtensionProviderSource.swift
//  DualCastCameraExtension
//
//  CoreMediaIO provider source that exposes two virtual cameras. Each camera
//  is an independent NDI receiver so Ecamm Live can see and switch between
//  them as ordinary webcams.
//

import CoreMediaIO
import Foundation

final class CameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

    private var cameras: [VirtualCameraDevice] = []

    override init() {
        super.init()

        cameras = [
            VirtualCameraDevice(
                localizedName: "DualCast Display 1",
                deviceID: UUID(uuidString: "A1B2C3D4-E5F6-7890-A1B2-C3D4E5F67890")!,
                legacyDeviceID: "DualCastDisplay1",
                assignedSourceKey: "dualcast.camera.source.1"
            ),
            VirtualCameraDevice(
                localizedName: "DualCast Display 2",
                deviceID: UUID(uuidString: "B2C3D4E5-F6A7-8901-B2C3-D4E5F6A78901")!,
                legacyDeviceID: "DualCastDisplay2",
                assignedSourceKey: "dualcast.camera.source.2"
            )
        ]
    }

    // MARK: - CMIOExtensionProviderSource

    var availableProperties: Set<CMIOExtensionProperty> {
        return []
    }

    func connect(to client: CMIOExtensionClient) throws {
    }

    func disconnect(from client: CMIOExtensionClient) {
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        return CMIOExtensionProviderProperties(dictionary: [:])
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
    }
}
