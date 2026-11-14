//
//  SyphonOutput.swift
//  DualCast Switcher
//
//  Publishes the active NDI slot as a local Syphon server so macOS visual apps
//  that don't support NDI (OBS via Syphon plugin, Resolume, Millumin, …) can
//  consume the switched feed with near-zero overhead.
//

import CoreVideo
import Metal
import OSLog
import Syphon

/// Thread-safe Syphon publisher for the Switcher's active video frame.
final class SyphonOutput: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.woodseedigi.dualcastswitcher",
        category: "SyphonOutput"
    )

    private let serverName: String
    private let queue = DispatchQueue(
        label: "com.woodseedigi.dualcastswitcher.syphon",
        qos: .userInitiated
    )

    private var device: MTLDevice?
    private var server: SyphonMetalServer?
    private var textureCache: CVMetalTextureCache?
    private var commandQueue: MTLCommandQueue?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    init(serverName: String = "DualCast Switcher") {
        self.serverName = serverName
    }

    deinit {
        stop()
    }

    /// Starts the Syphon server if Metal is available.
    func start() {
        queue.sync {
            guard server == nil else { return }
            guard let device = MTLCreateSystemDefaultDevice(),
                  let commandQueue = device.makeCommandQueue() else {
                Self.logger.error("Metal is not available; Syphon output cannot start.")
                return
            }
            self.device = device
            self.commandQueue = commandQueue

            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            guard status == kCVReturnSuccess, let cache else {
                Self.logger.error("Could not create Metal texture cache for Syphon.")
                return
            }
            textureCache = cache

            server = SyphonMetalServer(
                name: serverName,
                device: device,
                options: nil
            )
            Self.logger.info("Syphon server '\(self.serverName, privacy: .public)' started.")
        }
    }

    /// Stops the Syphon server and releases Metal resources.
    func stop() {
        queue.sync {
            server = nil
            textureCache = nil
            commandQueue = nil
            device = nil
            pixelBufferPool = nil
            poolWidth = 0
            poolHeight = 0
            Self.logger.info("Syphon server stopped.")
        }
    }

    var isRunning: Bool {
        queue.sync { server != nil }
    }

    /// Whether any Syphon clients are currently attached.
    var hasClients: Bool {
        queue.sync { server?.hasClients ?? false }
    }

    /// Publishes an NDI video frame to attached Syphon clients.
    /// Must be called from the NDI capture thread; serialised internally.
    func publish(_ frame: UnsafePointer<NDIlib_video_frame_v2_t>) {
        queue.sync {
            guard let server, let commandQueue, let textureCache else { return }

            let width = Int(ndilib_video_width(frame))
            let height = Int(ndilib_video_height(frame))
            guard width > 0, height > 0 else { return }

            guard let pixelBuffer = pixelBuffer(width: width, height: height) else { return }

            // Copy the NDI BGRA frame into the Metal-compatible pixel buffer,
            // handling row stride differences.
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            guard let src = ndilib_video_data(frame),
                  let dst = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

            let srcStride = Int(ndilib_video_stride(frame))
            let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let copyWidth = min(srcStride, dstStride)

            for row in 0..<height {
                let srcRow = src.advanced(by: row * srcStride)
                let dstRow = dst.advanced(by: row * dstStride)
                dstRow.copyMemory(from: srcRow, byteCount: copyWidth)
            }

            // Publish the buffer through Syphon.
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
            guard status == kCVReturnSuccess,
                  let cvTexture,
                  let texture = CVMetalTextureGetTexture(cvTexture) else {
                Self.logger.error("Could not create Metal texture from pixel buffer for Syphon.")
                return
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            let region = NSRect(x: 0, y: 0, width: width, height: height)
            server.publishFrameTexture(
                texture,
                on: commandBuffer,
                imageRegion: region,
                flipped: false
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
    }

    // MARK: - Pixel buffer pool

    private func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if poolWidth != width || poolHeight != height || pixelBufferPool == nil {
            pixelBufferPool = createPool(width: width, height: height)
            poolWidth = width
            poolHeight = height
        }
        guard let pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func createPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess else { return nil }
        return pool
    }
}
