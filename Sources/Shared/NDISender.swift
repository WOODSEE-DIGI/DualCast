//
//  NDISender.swift
//  DualCast
//
//  Swift wrapper around a single NDI send instance (NDIlib_send_*).
//
//  Threading: `send(bgraPixelBuffer:)` blocks briefly while NDI consumes the
//  frame, so it must be called from the owning capture queue only.
//  `connectionCount` and `tally` use non-blocking NDI polls (timeout 0) and
//  may be called from anywhere.
//

import CoreVideo
import Foundation

final class NDISender: @unchecked Sendable {
    enum SenderError: Error, LocalizedError {
        case creationFailed(String)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let name):
                return "NDI could not create the sender '\(name)'."
            }
        }
    }

    /// Tally state reported by connected receivers (e.g. OBS program/preview).
    struct Tally: Sendable {
        var onProgram: Bool = false
        var onPreview: Bool = false
    }

    let sourceName: String
    private let instance: NDIlib_send_instance_t
    private let fpsNum: Int32
    private let fpsDen: Int32

    init(sourceName: String, groups: String? = nil, framesPerSecond: Int = 30) throws {
        self.sourceName = sourceName
        self.fpsNum = Int32(framesPerSecond)
        self.fpsDen = 1

        let created: NDIlib_send_instance_t? = sourceName.withCString { namePtr in
            if let groups {
                return groups.withCString { groupsPtr in
                    var settings = NDIlib_send_create_t(
                        p_ndi_name: namePtr,
                        p_groups: groupsPtr,
                        clock_video: true,
                        clock_audio: false
                    )
                    return NDIlib_send_create(&settings)
                }
            }
            var settings = NDIlib_send_create_t(
                p_ndi_name: namePtr,
                p_groups: nil,
                clock_video: true,
                clock_audio: false
            )
            return NDIlib_send_create(&settings)
        }

        guard let instance = created else {
            throw SenderError.creationFailed(sourceName)
        }
        self.instance = instance
    }

    deinit {
        NDIlib_send_destroy(instance)
    }

    /// Submit one BGRA frame. Blocks until NDI's encoder has consumed it.
    /// Call only from the owning capture queue; the pixel buffer stays locked
    /// for the duration so the data pointer remains valid.
    func send(bgraPixelBuffer pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        let stride = Int32(CVPixelBufferGetBytesPerRow(pixelBuffer))

        ndilib_send_video_bgra(
            instance,
            baseAddress.assumingMemoryBound(to: UInt8.self),
            width, height, stride,
            fpsNum, fpsDen
        )
    }

    /// Relay passthrough: forward an already-populated NDI video frame (e.g.
    /// one received from another NDI source) without touching its fields.
    /// The frame's data must remain valid for the duration of the call.
    /// Call only while holding the sender's serialisation lock.
    func send(videoFrame frame: UnsafePointer<NDIlib_video_frame_v2_t>) {
        NDIlib_send_send_video_v2(instance, frame)
    }

    /// Number of receivers currently watching this source (non-blocking).
    var connectionCount: Int {
        Int(NDIlib_send_get_no_connections(instance, 0))
    }

    /// Last known tally state (non-blocking).
    var tally: Tally {
        var raw = NDIlib_tally_t()
        NDIlib_send_get_tally(instance, &raw, 0)
        return Tally(onProgram: raw.on_program, onPreview: raw.on_preview)
    }
}
