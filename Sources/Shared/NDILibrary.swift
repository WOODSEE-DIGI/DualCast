//
//  NDILibrary.swift
//  DualCast
//
//  One-time bootstrap and version info for libndi.
//

import Foundation

enum NDILibrary {
    /// True when libndi loaded, the CPU is supported, and the engine initialised.
    static let isAvailable: Bool = {
        guard NDIlib_is_supported_CPU() else { return false }
        return NDIlib_initialize()
    }()

    /// Human-readable NDI version string (e.g. "6.1.1" style), or "unavailable".
    static var version: String {
        guard isAvailable, let cVersion = NDIlib_version() else { return "unavailable" }
        return String(cString: cVersion)
    }
}
