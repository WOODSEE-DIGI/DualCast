//
//  DisplayCapture.swift
//  DualCast
//
//  Captures one SCDisplay via ScreenCaptureKit and forwards every frame to an
//  NDISender. All frame processing happens on a dedicated serial queue so the
//  NDI send calls are strictly single-threaded per sender instance.
//

import Accelerate
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
    var hasAudio: Bool = false
}

final class DisplayCapture: NSObject, @unchecked Sendable {
    struct Configuration: Sendable {
        var ndiSourceName: String
        var maxOutputWidth: Int = 2560
        var maxOutputHeight: Int = 1440
        var framesPerSecond: Int = 30
        var showsCursor: Bool = true
        /// Attach global system audio to this stream (48 kHz stereo FLTP).
        /// Only one display pipeline should have this enabled — macOS has no
        /// concept of per-display audio.
        var capturesSystemAudio: Bool = false
    }

    /// Seconds between preview thumbnails pushed to the UI.
    private static let previewInterval: TimeInterval = 0.7
    /// Length of the FPS measurement window.
    private static let statsWindow: TimeInterval = 1.0
    /// Preview thumbnail width in pixels.
    private static let previewWidth: CGFloat = 320
    /// Seconds between audio-level publishes.
    private static let audioLevelInterval: TimeInterval = 0.1

    let displayID: CGDirectDisplayID

    /// All NDI video sends and mutable capture state live on this serial queue.
    private let queue: DispatchQueue
    /// Audio callbacks run here; NDI documents audio and video may be sent
    /// from separate threads, so no lock is needed between the two queues.
    private let audioQueue: DispatchQueue

    // MARK: Queue-confined state (only touch on `queue`)
    private var stream: SCStream?
    private var sender: NDISender?
    private var isRunning = false
    private var framesInWindow: Int = 0
    private var windowStart: Date = .distantPast
    private var totalFrames: UInt64 = 0
    private var lastPreviewDate: Date = .distantPast
    private var outputSize: (width: Int, height: Int) = (0, 0)
    private var hasAudioOutput = false
    private lazy var previewContext = CIContext()

    // MARK: Audio-queue-confined state (only touch on `audioQueue`)
    /// ONE contiguous planar buffer ([ch0][ch1]...) — NDI FLTP layout.
    private var audioPlanarBuffer: UnsafeMutablePointer<Float>?
    private var audioPlanarCapacity: Int = 0
    private var lastAudioLevelDate: Date = .distantPast
    private var warnedAudioFormat = false
    #if DEBUG
    private var audioTXCount = 0
    private func audioDebugLog(_ message: String) {
        let line = "\(Date()): TX \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: "/tmp/dc-audio-tx.log") {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/dc-audio-tx.log"))
        }
    }
    #endif

    // MARK: Callbacks (always invoked on the main actor)
    var onStats: (@MainActor (CaptureStats) -> Void)?
    var onPreview: (@MainActor (CGImage) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onAudioLevel: (@MainActor (Float) -> Void)?

    init(display: SCDisplay) {
        self.displayID = display.displayID
        self.queue = DispatchQueue(
            label: "com.woodseedigi.dualcast.capture.\(display.displayID)",
            qos: .userInitiated
        )
        self.audioQueue = DispatchQueue(
            label: "com.woodseedigi.dualcast.audio.\(display.displayID)",
            qos: .userInitiated
        )
    }

    // MARK: - Lifecycle (call from main actor)

    func start(display: SCDisplay, excludingWindows: WindowExclusionList, configuration: Configuration) async throws {
        guard !isRunning else { return }

        let sender = try NDISender(
            sourceName: configuration.ndiSourceName,
            framesPerSecond: configuration.framesPerSecond,
            clockAudio: configuration.capturesSystemAudio
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
        streamConfig.capturesAudio = configuration.capturesSystemAudio
        if configuration.capturesSystemAudio {
            // 48 kHz stereo is the NDI standard; exclude our own app's audio.
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = 48000
            streamConfig.channelCount = 2
        }
        streamConfig.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            hasAudioOutput = true
        }

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
            if hasAudioOutput {
                try? stream.removeStreamOutput(self, type: .audio)
            }
        }
        hasAudioOutput = false
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
            outputHeight: outputSize.height,
            hasAudio: hasAudioOutput
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

    // MARK: - Audio processing (audioQueue only)

    /// Extracts planar Float32 channels from an SCK audio sample and sends
    /// them as an NDI FLTP frame. SCK is configured for 48 kHz stereo
    /// non-interleaved Float32, which maps directly onto NDI's FLTP layout
    /// with no conversion; an interleaved fallback deinterleaves into
    /// preallocated buffers if the format ever differs.
    private func processAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let sender else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        let asbd = asbdPointer.pointee

        var requiredSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, requiredSize > 0 else { return }

        let ablStorage = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: 16)
        defer { ablStorage.deallocate() }

        // The retained block buffer is ARC-managed in Swift (no manual release).
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablStorage.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat, asbd.mBitsPerChannel == 32 else {
            if !warnedAudioFormat {
                warnedAudioFormat = true
                NSLog("[DualCast] Dropping audio: unsupported format flags %u bits %u",
                      asbd.mFormatFlags, asbd.mBitsPerChannel)
            }
            return
        }

        let abl = UnsafeMutableAudioBufferListPointer(
            ablStorage.assumingMemoryBound(to: AudioBufferList.self)
        )
        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        let sampleRate = Int(asbd.mSampleRate)
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        #if DEBUG
        if audioTXCount == 0 {
            audioDebugLog("ASBD ch=\(channelCount) rate=\(sampleRate) nonInterleaved=\(isNonInterleaved) ablBuffers=\(abl.count) b0Bytes=\(abl.first?.mDataByteSize ?? 0)")
        }
        #endif

        // NDI FLTP requires ONE contiguous planar buffer ([ch0][ch1]...).
        // Build it from whatever SCK delivered (planar or interleaved).
        let sampleCount: Int
        if isNonInterleaved || channelCount == 1 || abl.count > 1 {
            sampleCount = abl.first.map { Int($0.mDataByteSize) / MemoryLayout<Float>.size } ?? 0
        } else {
            sampleCount = abl.first.map {
                Int($0.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            } ?? 0
        }
        guard sampleCount > 0 else { return }

        ensureAudioPlanarCapacity(floats: sampleCount * channelCount)
        guard let planar = audioPlanarBuffer else { return }

        if isNonInterleaved || channelCount == 1 || abl.count > 1 {
            // Planar source: copy each channel's AudioBuffer into place.
            if abl.count < channelCount {
                memset(planar, 0, sampleCount * channelCount * MemoryLayout<Float>.size)
            }
            for channel in 0..<min(channelCount, abl.count) {
                guard let source = abl[channel].mData else { continue }
                memcpy(
                    planar.advanced(by: channel * sampleCount),
                    source,
                    sampleCount * MemoryLayout<Float>.size
                )
            }
        } else {
            // Interleaved source: deinterleave into planar layout.
            let interleaved = abl.first!.mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<sampleCount {
                for channel in 0..<channelCount {
                    planar[channel * sampleCount + frame] = interleaved[frame * channelCount + channel]
                }
            }
        }

        publishAudioLevel(planar: planar, sampleCount: sampleCount, channelCount: channelCount)
        sender.send(
            fltpPlanarData: UnsafePointer(planar),
            channelCount: channelCount,
            sampleRate: sampleRate,
            sampleCount: sampleCount
        )
        #if DEBUG
        audioTXCount += 1
        if audioTXCount % 100 == 1 {
            audioDebugLog("frame #\(audioTXCount) samples=\(sampleCount) ch=\(channelCount) rate=\(sampleRate) peakSent")
        }
        #endif
    }

    private func ensureAudioPlanarCapacity(floats: Int) {
        guard floats > audioPlanarCapacity else { return }
        audioPlanarBuffer?.deallocate()
        let capacity = max(floats * 2, 9600)
        audioPlanarBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        audioPlanarCapacity = capacity
    }

    /// Peak level across channels, published to the UI at ~10 Hz.
    private func publishAudioLevel(planar: UnsafePointer<Float>, sampleCount: Int, channelCount: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastAudioLevelDate) >= Self.audioLevelInterval else { return }
        lastAudioLevelDate = now

        var peak: Float = 0
        for channel in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(planar.advanced(by: channel * sampleCount), 1, &channelPeak, vDSP_Length(sampleCount))
            peak = max(peak, channelPeak)
        }

        let level = min(peak, 1)
        let callback = onAudioLevel
        Task { @MainActor in callback?(level) }
    }
}

// MARK: - SCStreamOutput

extension DisplayCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Video arrives on `queue`; audio arrives on `audioQueue`
        // (the handler queues passed to addStreamOutput).
        if type == .audio {
            guard isRunning else { return }
            processAudioSample(sampleBuffer)
            return
        }
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
