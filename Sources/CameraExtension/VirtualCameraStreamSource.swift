//
//  VirtualCameraStreamSource.swift
//  DualCastCameraExtension
//
//  Stream source for one virtual camera. Receives its assigned NDI source
//  directly in the extension process, scales frames to 1280x720 BGRA, and
//  forwards them to the CMIO client (Ecamm Live, etc.).
//

import Accelerate
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

final class VirtualCameraStreamSource: NSObject, @unchecked Sendable, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let formatDescription: CMFormatDescription
    private let assignedSourceKey: String

    private var streaming = false
    private var ndiFinder: NDIFinder?
    private var ndiReceiver: NDIReceiver?
    private var frameCount: Int64 = 0
    private var connectedSourceName: String?
    private var lastDiscoveredSources: [NDISourceInfo] = []
    private var assignmentWatchTask: Task<Void, Never>?

    // 1280x720 BGRA @ 30 fps — widely supported by Ecamm/OBS/etc.
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let fps: Int32 = 30

    init(assignedSourceKey: String) {
        self.assignedSourceKey = assignedSourceKey

        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Self.width,
            height: Self.height,
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard let formatDescription = fmt else {
            fatalError("[DualCastCameraExtension] Could not create video format description")
        }
        self.formatDescription = formatDescription

        super.init()

        self.stream = CMIOExtensionStream(
            localizedName: "DualCast Virtual Camera Stream",
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    // MARK: - CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] {
        return [
            CMIOExtensionStreamFormat(
                formatDescription: formatDescription,
                maxFrameDuration: CMTime(value: 1, timescale: Self.fps),
                minFrameDuration: CMTime(value: 1, timescale: Self.fps),
                validFrameDurations: nil
            )
        ]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = 0
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        return true
    }

    func startStream() throws {
        guard !streaming else { return }
        streaming = true

        guard NDILibrary.isAvailable else {
            throw NSError(
                domain: "DualCastCameraExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "NDI library not available"]
            )
        }

        let finder = NDIFinder()
        finder.onSourcesChanged = { [weak self] sources in
            self?.handleDiscoveredSources(sources)
        }
        finder.start()
        ndiFinder = finder

        // If the assignment is already known, try to connect immediately.
        if let name = assignedSourceName(), !name.isEmpty {
            handleDiscoveredSources([])
        }

        assignmentWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(2 * 1_000_000_000))
                guard let self, self.streaming else { return }
                self.checkAssignmentChanged()
            }
        }
    }

    func stopStream() throws {
        streaming = false
        assignmentWatchTask?.cancel()
        assignmentWatchTask = nil
        ndiReceiver?.disconnect()
        ndiReceiver = nil
        ndiFinder?.stop()
        ndiFinder = nil
        connectedSourceName = nil
    }

    // MARK: - NDI discovery & receive

    private func assignedSourceName() -> String? {
        return UserDefaults(suiteName: "group.com.woodseedigi.DualCast")?
            .string(forKey: assignedSourceKey)
    }

    private func handleDiscoveredSources(_ sources: [NDISourceInfo]) {
        lastDiscoveredSources = sources
        guard streaming, ndiReceiver == nil else { return }
        guard let assignedName = assignedSourceName(), !assignedName.isEmpty else { return }

        if let source = sources.first(where: { $0.name == assignedName }) {
            connect(to: source)
        }
    }

    private func checkAssignmentChanged() {
        guard streaming else { return }
        let assignedName = assignedSourceName() ?? ""
        if connectedSourceName != nil, connectedSourceName != assignedName {
            NSLog("[DualCastCameraExtension] Assignment changed from '%@' to '%@', reconnecting.", connectedSourceName ?? "", assignedName)
            ndiReceiver?.disconnect()
            ndiReceiver = nil
            connectedSourceName = nil
            handleDiscoveredSources(lastDiscoveredSources)
        }
    }

    private func connect(to source: NDISourceInfo) {
        let receiver = NDIReceiver()
        receiver.onVideoFrame = { [weak self] videoFrame in
            self?.handleVideoFrame(videoFrame)
        }
        receiver.onStopped = { [weak self] in
            guard let self, self.streaming else { return }
            NSLog("[DualCastCameraExtension] Receiver stopped for '%@'", source.name)
            self.ndiReceiver = nil
            self.connectedSourceName = nil
        }
        receiver.connect(to: source)
        ndiReceiver = receiver
        connectedSourceName = source.name
    }

    private func handleVideoFrame(_ frame: UnsafePointer<NDIlib_video_frame_v2_t>) {
        guard streaming else { return }

        guard let sampleBuffer = createSampleBuffer(from: frame) else { return }

        frameCount += 1
        let hostTime = UInt64(mach_absolute_time())
        stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }

    // MARK: - Frame conversion

    private func createSampleBuffer(from frame: UnsafePointer<NDIlib_video_frame_v2_t>) -> CMSampleBuffer? {
        let srcWidth = Int(frame.pointee.xres)
        let srcHeight = Int(frame.pointee.yres)
        let srcData = frame.pointee.p_data
        let srcStride = Int(frame.pointee.line_stride_in_bytes)
        let frameFourCC = frame.pointee.FourCC

        guard srcWidth > 0, srcHeight > 0, let srcData else {
            NSLog("[DualCastCameraExtension] Invalid NDI frame dimensions")
            return nil
        }

        // NDI commonly sends BGRA or BGRX. Both are 32-bit little-endian BGR
        // with an alpha/X byte in the high byte.
        let fourCC_BGRA = fourCC(from: "BGRA")
        let fourCC_BGRX = fourCC(from: "BGRX")
        guard frameFourCC == fourCC_BGRA || frameFourCC == fourCC_BGRX else {
            NSLog("[DualCastCameraExtension] Unsupported NDI FourCC: %u", frameFourCC)
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(Self.width),
            Int(Self.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let dstBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstWidth = Int(Self.width)
        let dstHeight = Int(Self.height)

        if srcWidth == dstWidth && srcHeight == dstHeight {
            copyBGRXToBGRA(
                src: srcData,
                srcStride: srcStride,
                dst: dstBase,
                dstStride: dstStride,
                width: srcWidth,
                height: srcHeight
            )
        } else {
            scaleBGRXToBGRA(
                src: srcData,
                srcWidth: srcWidth,
                srcHeight: srcHeight,
                srcStride: srcStride,
                dst: dstBase,
                dstWidth: dstWidth,
                dstHeight: dstHeight,
                dstStride: dstStride
            )
        }

        let pts = CMTime(value: frameCount, timescale: Self.fps)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Self.fps),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    /// Copies identical-size BGRX/BGRA to BGRA with opaque alpha.
    private func copyBGRXToBGRA(
        src: UnsafeMutablePointer<UInt8>,
        srcStride: Int,
        dst: UnsafeMutableRawPointer,
        dstStride: Int,
        width: Int,
        height: Int
    ) {
        let dstPixels = dst.assumingMemoryBound(to: UInt32.self)
        let dstRowPixels = dstStride / 4

        for y in 0..<height {
            let srcRow = src.advanced(by: y * srcStride)
                .withMemoryRebound(to: UInt32.self, capacity: width) { $0 }
            for x in 0..<width {
                dstPixels[y * dstRowPixels + x] = (srcRow[x] & 0x00FFFFFF) | 0xFF000000
            }
        }
    }

    /// Builds a little-endian FourCC value from a 4-character string.
    private func fourCC(from string: String) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in string.utf8.enumerated() {
            value |= UInt32(byte) << (index * 8)
        }
        return value
    }

    /// Scales BGRX/BGRA to BGRA with opaque alpha using Accelerate.vImage.
    private func scaleBGRXToBGRA(
        src: UnsafeMutablePointer<UInt8>,
        srcWidth: Int,
        srcHeight: Int,
        srcStride: Int,
        dst: UnsafeMutableRawPointer,
        dstWidth: Int,
        dstHeight: Int,
        dstStride: Int
    ) {
        // vImageScale_ARGB8888 works on any 4-channel 8-bit interleaved buffer.
        var srcBuffer = vImage_Buffer(
            data: src,
            height: vImagePixelCount(srcHeight),
            width: vImagePixelCount(srcWidth),
            rowBytes: srcStride
        )
        var dstBuffer = vImage_Buffer(
            data: dst,
            height: vImagePixelCount(dstHeight),
            width: vImagePixelCount(dstWidth),
            rowBytes: dstStride
        )

        let error = vImageScale_ARGB8888(
            &srcBuffer,
            &dstBuffer,
            nil,
            vImage_Flags(kvImageHighQualityResampling)
        )
        guard error == kvImageNoError else {
            NSLog("[DualCastCameraExtension] vImageScale failed: %ld", error)
            return
        }

        // Force opaque alpha on every pixel.
        let dstPixels = dst.assumingMemoryBound(to: UInt32.self)
        let dstRowPixels = dstStride / 4
        for y in 0..<dstHeight {
            for x in 0..<dstWidth {
                dstPixels[y * dstRowPixels + x] |= 0xFF000000
            }
        }
    }
}
