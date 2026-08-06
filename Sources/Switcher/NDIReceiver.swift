//
//  NDIReceiver.swift
//  DualCast Switcher
//
//  Receives one NDI source on a dedicated capture thread. Video frames are
//  delivered to `onVideoFrame` while they are still valid (they are freed
//  immediately after the callback returns), so consumers must do all work —
//  relay send, preview render — synchronously inside the callback.
//
//  The recv instance is created and destroyed on the capture thread; the
//  only cross-thread mutation is the `shouldRun` flag (lock-protected).
//

import Foundation

final class NDIReceiver: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case idle
        case connecting
        case receiving
        case failed(String)
    }

    /// Called on the capture thread per video frame, while the frame is valid.
    var onVideoFrame: ((UnsafePointer<NDIlib_video_frame_v2_t>) -> Void)?
    /// Called on the capture thread per audio frame, while the frame is valid.
    var onAudioFrame: ((UnsafePointer<NDIlib_audio_frame_v3_t>) -> Void)?
    /// Called when the capture thread has fully torn down (recv destroyed).
    var onStopped: (() -> Void)?
    /// Called on the main actor when status changes.
    var onStatus: (@MainActor (Status) -> Void)?

    private(set) var source: NDISourceInfo?
    private var shouldRun = false
    private let lock = NSLock()
    private var thread: Thread?

    /// Starts (or restarts) reception of the given source.
    func connect(to source: NDISourceInfo) {
        disconnect()
        lock.lock()
        self.source = source
        shouldRun = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.captureLoop(source: source)
        }
        thread.name = "com.woodseedigi.dualcast.switcher.recv.\(source.shortName)"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    /// Signals the capture loop to exit. Teardown (recv destroy) completes
    /// asynchronously on the capture thread; `onStopped` fires when done.
    func disconnect() {
        lock.lock()
        shouldRun = false
        lock.unlock()
    }

    private func isRunning() -> Bool {
        lock.withLock { shouldRun }
    }

    private func report(_ status: Status) {
        let callback = onStatus
        Task { @MainActor in callback?(status) }
    }

    private func captureLoop(source: NDISourceInfo) {
        report(.connecting)

        let instance: NDIlib_recv_instance_t? = source.name.withCString { namePtr in
            source.urlAddress.withCString { urlPtr in
                "DualCast Switcher".withCString { recvNamePtr in
                    var rawSource = NDIlib_source_t(
                        p_ndi_name: namePtr,
                        p_url_address: urlPtr
                    )
                    var create = NDIlib_recv_create_v3_t(
                        source_to_connect_to: rawSource,
                        color_format: NDIlib_recv_color_format_BGRX_BGRA,
                        bandwidth: NDIlib_recv_bandwidth_highest,
                        allow_video_fields: false,
                        p_ndi_recv_name: recvNamePtr
                    )
                    return NDIlib_recv_create_v3(&create)
                }
            }
        }

        guard let instance else {
            report(.failed("Could not connect to \(source.shortName)"))
            onStopped?()
            return
        }

        report(.receiving)
        NSLog("[Switcher] recv created for: %@ url: %@", source.name, source.urlAddress)

        guard let video = ndilib_video_frame_alloc(),
              let audio = ndilib_audio_frame_alloc() else {
            NDIlib_recv_destroy(instance)
            report(.failed("Out of memory"))
            onStopped?()
            return
        }
        defer {
            ndilib_video_frame_free(video)
            ndilib_audio_frame_free(audio)
        }

        var consecutiveErrors = 0

        while isRunning() {
            let frameType = NDIlib_recv_capture_v3(instance, video, audio, nil, 500)

            if frameType == NDIlib_frame_type_video {
                consecutiveErrors = 0
                onVideoFrame?(UnsafePointer(video))
                NDIlib_recv_free_video_v2(instance, video)
            } else if frameType == NDIlib_frame_type_audio {
                consecutiveErrors = 0
                onAudioFrame?(UnsafePointer(audio))
                NDIlib_recv_free_audio_v3(instance, audio)
            } else if frameType == NDIlib_frame_type_none {
                // Timeout with no frame — normal for low-frame-rate sources.
                consecutiveErrors = 0
            } else if frameType == NDIlib_frame_type_error {
                consecutiveErrors += 1
                if consecutiveErrors >= 4 {
                    report(.failed("Source error"))
                    break
                }
            }
            // status_change / metadata / audio: nothing to do.
        }

        NDIlib_recv_destroy(instance)
        onStopped?()
    }
}
