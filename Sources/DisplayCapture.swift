//
//  DisplayCapture.swift
//  DualCast
//
//  Captures one SCDisplay via ScreenCaptureKit and forwards every frame to an
//  NDISender. All frame processing happens on a dedicated serial queue so the
//  NDI send calls are strictly single-threaded per sender instance.
//

import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// Snapshot of a running pipeline, published to the UI about once per second.
struct CaptureStats: Sendable {
    var isStreaming: Bool = false
    var framesPerSecond: Double = 0
    var framesSent: UInt64 = 0
    var outputWidth: Int = 0
    var outputHeight: Int = 0
    var connections: Int = 0
    var onProgram: Bool = false
    var onPreview: Bool = false
}

final class DisplayCapture: NSObject, @unchecked Sendable {
    struct Configuration: Sendable {
        var ndiSourceName: String
        var maxOutputWidth: Int = 2560
        var maxOutputHeight: Int = 1440
        var framesPerSecond: Int = 30
        var showsCursor: Bool = true
    }

    /// Seconds between preview thumbnails pushed to the UI.
    private static let previewInterval: TimeInterval = 0.7
    /// Length of the FPS measurement window.
    private static let statsWindow: TimeInterval = 1.0
    /// Preview thumbnail width in pixels.
    private static let previewWidth: CGFloat = 320

    let displayID: CGDirectDisplayID

    /// All NDI sends and mutable capture state live on this serial queue.
    private let queue: DispatchQueue

    // MARK: Queue-confined state (only touch on `queue`)
    private var stream: SCStream?
    private var sender: NDISender?
    private var isRunning = false
    private var framesInWindow: Int = 0
    private var windowStart: Date = .distantPast
    private var totalFrames: UInt64 = 0
    private var lastPreviewDate: Date = .distantPast
    private var outputSize: (width: Int, height: Int) = (0, 0)
    private lazy var previewContext = CIContext()

    // MARK: Callbacks (always invoked on the main actor)
    var onStats: (@MainActor (CaptureStats) -> Void)?
    var onPreview: (@MainActor (CGImage) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    init(display: SCDisplay) {
        self.displayID = display.displayID
        self.queue = DispatchQueue(
            label: "com.woodseedigi.dualcast.capture.\(display.displayID)",
            qos: .userInitiated
        )
    }

    // MARK: - Lifecycle (call from main actor)

    func start(display: SCDisplay, excludingWindows: WindowExclusionList, configuration: Configuration) async throws {
        guard !isRunning else { return }

        let sender = try NDISender(
            sourceName: configuration.ndiSourceName,
            framesPerSecond: configuration.framesPerSecond
        )

        let target = Self.scaledOutputSize(
            sourceWidth: display.width,
            sourceHeight: display.height,
            maxWidth: configuration.maxOutputWidth,
            maxHeight: configuration.maxOutputHeight
        )

        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows.windows)

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = target.width
        streamConfig.height = target.height
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.framesPerSecond)
        )
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.queueDepth = 5
        streamConfig.showsCursor = configuration.showsCursor
        streamConfig.capturesAudio = false
        streamConfig.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        self.stream = stream
        self.sender = sender
        self.outputSize = target

        try await stream.startCapture()
        isRunning = true
        reportStats(force: true)
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        do {
            try await stream?.stopCapture()
        } catch {
            await emitError("Stop capture failed: \(error.localizedDescription)")
        }
        if let stream {
            try? stream.removeStreamOutput(self, type: .screen)
        }
        stream = nil
        sender = nil
    }

    /// Non-blocking NDI status poll. Safe to call from a detached task.
    func pollStatus() -> (connections: Int, tally: NDISender.Tally) {
        queue.sync {
            guard let sender else { return (0, NDISender.Tally()) }
            return (sender.connectionCount, sender.tally)
        }
    }

    // MARK: - Output sizing

    /// Scales the display's native pixel size to fit the configured box,
    /// preserving aspect ratio and rounding to even dimensions (codec-friendly).
    static func scaledOutputSize(sourceWidth: Int, sourceHeight: Int,
                                 maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (maxWidth, maxHeight) }
        let scale = min(Double(maxWidth) / Double(sourceWidth),
                        Double(maxHeight) / Double(sourceHeight), 1.0)
        let width = (Double(sourceWidth) * scale).rounded(.down)
        let height = (Double(sourceHeight) * scale).rounded(.down)
        return (Int(width) & ~1, Int(height) & ~1)
    }

    // MARK: - Queue-confined helpers

    private func reportStats(force: Bool = false) {
        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)
        guard force || elapsed >= Self.statsWindow else { return }

        let fps = elapsed > 0 ? Double(framesInWindow) / elapsed : 0
        let stats = CaptureStats(
            isStreaming: isRunning,
            framesPerSecond: fps,
            framesSent: totalFrames,
            outputWidth: outputSize.width,
            outputHeight: outputSize.height
        )
        framesInWindow = 0
        windowStart = now

        let callback = onStats
        Task { @MainActor in callback?(stats) }
    }

    private func emitError(_ message: String) async {
        let callback = onError
        await MainActor.run { callback?(message) }
    }

    private func makePreview(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = Self.previewWidth / extent.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return previewContext.createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - SCStreamOutput

extension DisplayCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Arrives on `queue` (the sample handler queue passed to addStreamOutput).
        guard type == .screen, isRunning, let sender else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        sender.send(bgraPixelBuffer: pixelBuffer)

        totalFrames += 1
        framesInWindow += 1
        reportStats()

        let now = Date()
        if now.timeIntervalSince(lastPreviewDate) >= Self.previewInterval,
           let preview = makePreview(from: pixelBuffer) {
            lastPreviewDate = now
            let callback = onPreview
            Task { @MainActor in callback?(preview) }
        }
    }
}

// MARK: - SCStreamDelegate

extension DisplayCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        isRunning = false
        let callback = onError
        Task { @MainActor in
            callback?("Capture stopped: \(error.localizedDescription)")
        }
    }
}
