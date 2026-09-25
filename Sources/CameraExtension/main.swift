//
//  main.swift
//  DualCastCameraExtension
//
//  Entry point for the CoreMediaIO camera extension.
//

import CoreMediaIO
import Foundation

// Eagerly initialise NDI in the extension process.
if NDILibrary.isAvailable {
    NSLog("[DualCastCameraExtension] NDI available: %@", NDILibrary.version)
} else {
    NSLog("[DualCastCameraExtension] NDI not available")
}

let provider = CMIOExtensionProvider(
    source: CameraExtensionProviderSource(),
    clientQueue: nil
)
CMIOExtensionProvider.startService(provider: provider)
CFRunLoopRun()
