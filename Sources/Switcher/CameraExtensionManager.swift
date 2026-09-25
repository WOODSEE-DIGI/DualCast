//
//  CameraExtensionManager.swift
//  DualCast Switcher
//
//  Activates the embedded CoreMediaIO camera extension so Ecamm Live can see
//  the virtual cameras. The extension runs as a separate process and receives
//  NDI directly; the host app only needs to activate it once.
//

import Foundation
import SystemExtensions

@MainActor
final class CameraExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    static let shared = CameraExtensionManager()

    @Published private(set) var activationState: ActivationState = .unknown
    @Published private(set) var lastError: String?

    enum ActivationState: String {
        case unknown = "Unknown"
        case activating = "Activating…"
        case activated = "Activated"
        case needsApproval = "Needs approval in System Settings"
        case failed = "Failed"
    }

    private let extensionIdentifier = "com.woodseedigi.DualCastSwitcher.CameraExtension"

    func activate() {
        guard activationState != .activating else { return }
        activationState = .activating
        lastError = nil

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .global(qos: .userInitiated)
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.activationState = .needsApproval
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.activationState = .failed
            self.lastError = error.localizedDescription
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.activationState = .activated
            case .willCompleteAfterReboot:
                self.activationState = .needsApproval
            @unknown default:
                self.activationState = .unknown
            }
        }
    }
}
