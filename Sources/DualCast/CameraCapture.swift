//
//  CameraCapture.swift
//  DualCast
//
//  Captures one AVCaptureDevice (FaceTime / USB webcam) and forwards frames
//  to an NDISender. Mirrors DisplayCapture's callback shape so StreamManager
//  can treat cameras and displays similarly.
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation

final class CameraCapture: NSObject, @unchecked Sendable {
    struct Configuration: Sendable {
        var ndiSourceName: String
        var framesPerSecond: Int = 30
        var maxOutputWidth: Int = 1920
        var maxOutputHeight: Int = 1080
    }

    /// Called on the capture queue for every frame; pixel buffer is valid only
    /// for the duration of the call.
    var onVideoFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main actor with a downscaled preview thumbnail.
    var onPreview: (@MainActor (CGImage) -> Void)?
    /// Called on the main actor when status changes.
    var onStatus: (@MainActor (CaptureStats) -> Void)?
    /// Called on the main actor on failure.
    var onError: (@MainActor (String) -> Void)?

    private let device: AVCaptureDevice
    private let queue: DispatchQueue
    private var session: AVCaptureSession?
    private var sender: NDISender?

    private var framesInWindow: Int = 0
    private var windowStart: Date = .distantPast
    private var totalFrames: UInt64 = 0
    private var lastPreviewDate: Date = .distantPast
    private lazy var previewContext = CIContext()

    init(device: AVCaptureDevice) {
        self.device = device
        self.queue = DispatchQueue(label: "com.woodseedigi.dualcast.camera.\(device.uniqueID)")
        super.init()
    }

    // MARK: - Lifecycle

    func start(configuration: Configuration) async throws {
        guard session == nil else { return }

        let session = AVCaptureSession()
        self.session = session

        // Cap the session preset to keep bandwidth reasonable.
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Request BGRA so we can pass the pixel buffer straight to NDI.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)

        let sender = try NDISender(
            sourceName: configuration.ndiSourceName,
            framesPerSecond: configuration.framesPerSecond,
            clockAudio: false
        )
        self.sender = sender

        session.startRunning()
    }

    func stop() async {
        guard let session else { return }
        self.session = nil
        session.stopRunning()
        sender = nil
    }

    var isStreaming: Bool {
        session?.isRunning ?? false
    }

    var connectionCount: Int {
        sender?.connectionCount ?? 0
    }

    var tally: NDISender.Tally {
        sender?.tally ?? NDISender.Tally()
    }

    // MARK: - Frame handling

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pixelBuffer = imageBuffer

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        sender?.send(bgraPixelBuffer: pixelBuffer)
        onVideoFrame?(pixelBuffer)

        totalFrames += 1
        framesInWindow += 1

        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)
        if elapsed >= 1.0 {
            let fps = Double(framesInWindow) / elapsed
            let stats = CaptureStats(
                isStreaming: true,
                framesPerSecond: fps,
                framesSent: totalFrames,
                outputWidth: width,
                outputHeight: height,
                connections: sender?.connectionCount ?? 0
            )
            Task { @MainActor in self.onStatus?(stats) }
            framesInWindow = 0
            windowStart = now
        }

        if now.timeIntervalSince(lastPreviewDate) >= 0.7 {
            lastPreviewDate = now
            if let preview = renderPreview(pixelBuffer) {
                Task { @MainActor in self.onPreview?(preview) }
            }
        }
    }

    private func renderPreview(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 160.0 / Double(CVPixelBufferGetWidth(pixelBuffer))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return previewContext.createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - Errors

enum CameraCaptureError: Error, LocalizedError {
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "Cannot add camera input to capture session."
        case .cannotAddOutput:
            return "Cannot add video output to capture session."
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handleSampleBuffer(sampleBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Dropped frames are normal under load; no action needed.
    }
}
