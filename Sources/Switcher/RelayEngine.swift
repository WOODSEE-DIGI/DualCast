//
//  RelayEngine.swift
//  DualCast Switcher
//
//  Owns the output NDI sender and one NDIReceiver per input slot. Forwards
//  frames from the ACTIVE slot to the output (zero-copy passthrough — the
//  received NDI frame descriptor is handed straight to the sender, no
//  pixel recompression), while generating downscaled previews for both.
//
//  Threading: receivers call forward(_:from:) concurrently from their own
//  capture threads, so the output send is serialised behind sendLock (NDI
//  senders are not thread-safe). Slot switching is just an atomic flag
//  change — both inputs stay at highest bandwidth, so switching is
//  instant (no renegotiation latency).
//

import CoreImage
import Foundation

final class RelayEngine: @unchecked Sendable {
    static let slotCount = 2

    struct SlotStats: Sendable {
        var framesPerSecond: Double = 0
        var framesReceived: UInt64 = 0
    }

    // MARK: Callbacks (invoked on the main actor)

    var onActiveSlotChanged: (@MainActor (Int) -> Void)?
    var onPreview: (@MainActor (Int, CGImage) -> Void)?
    var onSlotStats: (@MainActor (Int, SlotStats) -> Void)?
    var onReceiverStatus: (@MainActor (Int, NDIReceiver.Status) -> Void)?
    var onReceiverStopped: ((Int) -> Void)?

    // MARK: State

    private var sender: NDISender?
    private var receivers: [Int: NDIReceiver] = [:]
    private var activeSlot = 0
    private var running = false

    /// Serialises all sends to the single output NDI instance.
    private let sendLock = NSLock()
    /// Guards activeSlot / receivers / running.
    private let stateLock = NSLock()

    // Stats + preview throttling. Each slot is confined to its own capture
    // thread, but the DICTIONARIES are shared mutable state — Swift Dictionary
    // mutation is not thread-safe even across different keys, so all access
    // goes through statsLock. (Unlocked concurrent subscript writes here were
    // the cause of a heap-corruption crash.)
    private var framesInWindow: [Int: Int] = [:]
    private var windowStart: [Int: Date] = [:]
    private var totalFrames: [Int: UInt64] = [:]
    private var lastPreviewDate: [Int: Date] = [:]
    /// Last time each slot received an audio frame (for the UI indicator).
    private var lastAudioDate: [Int: Date] = [:]
    private let statsLock = NSLock()
    private let previewContext = CIContext()

    private static let statsWindow: TimeInterval = 1.0
    private static let previewInterval: TimeInterval = 0.5
    private static let previewWidth: CGFloat = 384

    // MARK: - Lifecycle

    func start(outputName: String, slots: [Int: NDISourceInfo]) throws {
        stateLock.withLock {
            guard !running else { return }
            running = true
        }

        let sender = try NDISender(sourceName: outputName, framesPerSecond: 30,
                                   clockAudio: true)
        sendLock.lock()
        self.sender = sender
        sendLock.unlock()

        for (slot, source) in slots {
            attach(slot: slot, source: source)
        }
    }

    func stop() async {
        stateLock.withLock {
            guard running else { return }
            running = false
        }
        for receiver in currentReceivers().values {
            receiver.disconnect()
        }
        // Capture threads tear down asynchronously; wait until the recv
        // instances are destroyed before dropping the sender (max ~2 s).
        for _ in 0..<40 {
            if currentReceivers().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        sendLock.withLock {
            sender = nil
        }
    }

    var isRunning: Bool {
        stateLock.withLock { running }
    }

    // MARK: - Slot management

    /// (Re)connects a slot to a source. Safe to call while running
    /// (e.g. for automatic reconnect after the source reappears).
    func attach(slot: Int, source: NDISourceInfo) {
        guard isRunning else { return }

        if let existing = currentReceivers()[slot] {
            existing.disconnect()
            stateLock.withLock { receivers[slot] = nil }
        }

        let receiver = NDIReceiver()
        receiver.onVideoFrame = { [weak self] frame in
            self?.forward(frame, from: slot)
        }
        receiver.onAudioFrame = { [weak self] frame in
            self?.forwardAudio(frame, from: slot)
        }
        receiver.onStatus = { [weak self] status in
            guard let callback = self?.onReceiverStatus else { return }
            Task { @MainActor in callback(slot, status) }
        }
        receiver.onStopped = { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                // Only remove if this receiver is still the registered one.
                if self.receivers[slot] === receiver {
                    self.receivers[slot] = nil
                }
            }
            self.onReceiverStopped?(slot)
        }

        stateLock.withLock { receivers[slot] = receiver }
        receiver.connect(to: source)
    }

    func setActiveSlot(_ slot: Int) {
        guard (0..<Self.slotCount).contains(slot) else { return }
        let changed = stateLock.withLock { () -> Bool in
            if activeSlot == slot { return false }
            activeSlot = slot
            return true
        }
        if changed, let callback = onActiveSlotChanged {
            Task { @MainActor in callback(slot) }
        }
    }

    func toggleSlot() {
        let next = stateLock.withLock { (activeSlot + 1) % Self.slotCount }
        setActiveSlot(next)
    }

    var currentActiveSlot: Int {
        stateLock.withLock { activeSlot }
    }

    // MARK: - Output status (non-blocking)

    var outputConnectionCount: Int {
        sendLock.lock()
        defer { sendLock.unlock() }
        return sender?.connectionCount ?? 0
    }

    var outputTally: NDISender.Tally {
        sendLock.lock()
        defer { sendLock.unlock() }
        return sender?.tally ?? NDISender.Tally()
    }

    /// True when a slot has received audio within the last 2 seconds.
    func audioAlive(for slot: Int) -> Bool {
        statsLock.withLock {
            guard let last = lastAudioDate[slot] else { return false }
            return Date().timeIntervalSince(last) < 2
        }
    }

    // MARK: - Frame forwarding (capture threads)

    private func forward(_ frame: UnsafePointer<NDIlib_video_frame_v2_t>, from slot: Int) {
        updateStats(for: slot)
        maybeRenderPreview(frame, for: slot)

        let isActive = stateLock.withLock { activeSlot == slot }
        guard isActive else { return }

        sendLock.lock()
        sender?.send(videoFrame: frame)
        sendLock.unlock()
    }

    private func forwardAudio(_ frame: UnsafePointer<NDIlib_audio_frame_v3_t>, from slot: Int) {
        statsLock.withLock { lastAudioDate[slot] = Date() }

        // Audio is forwarded regardless of the active video slot: macOS
        // system audio is global, not per-display, and only the
        // audio-carrying source produces audio frames — so forwarding every
        // incoming audio frame yields CONTINUOUS audio across display
        // switches, which is what a stream wants. (If both inputs ever
        // carried audio this would need an active-slot guard to avoid
        // doubling; DualCast enforces a single audio display.)
        sendLock.lock()
        sender?.send(audioFrame: frame)
        sendLock.unlock()
    }

    private func updateStats(for slot: Int) {
        let now = Date()

        let stats: SlotStats? = statsLock.withLock {
            totalFrames[slot, default: 0] += 1
            framesInWindow[slot, default: 0] += 1

            // distantPast default: the first window reports immediately —
            // using `?? now` here previously meant elapsed was always ~0
            // and stats never published.
            let start = windowStart[slot] ?? .distantPast
            let elapsed = now.timeIntervalSince(start)
            guard elapsed >= Self.statsWindow else { return nil }

            let result = SlotStats(
                framesPerSecond: Double(framesInWindow[slot] ?? 0) / elapsed,
                framesReceived: totalFrames[slot] ?? 0
            )
            framesInWindow[slot] = 0
            windowStart[slot] = now
            return result
        }

        guard let stats, let callback = onSlotStats else { return }
        Task { @MainActor in callback(slot, stats) }
    }

    private func maybeRenderPreview(_ frame: UnsafePointer<NDIlib_video_frame_v2_t>, for slot: Int) {
        let now = Date()
        let shouldRender = statsLock.withLock { () -> Bool in
            if let last = lastPreviewDate[slot],
               now.timeIntervalSince(last) < Self.previewInterval {
                return false
            }
            lastPreviewDate[slot] = now
            return true
        }
        guard shouldRender else { return }

        guard let data = ndilib_video_data(frame) else { return }
        let width = Int(ndilib_video_width(frame))
        let height = Int(ndilib_video_height(frame))
        let stride = Int(ndilib_video_stride(frame))
        guard width > 0, height > 0, stride > 0 else { return }

        let bytes = Data(bytesNoCopy: data, count: stride * height, deallocator: .none)
        let image = CIImage(
            bitmapData: bytes,
            bytesPerRow: stride,
            size: CGSize(width: width, height: height),
            format: .BGRA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        let scale = Self.previewWidth / CGFloat(width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = previewContext.createCGImage(scaled, from: scaled.extent) else { return }

        let callback = onPreview
        Task { @MainActor in callback?(slot, cgImage) }
    }

    private func currentReceivers() -> [Int: NDIReceiver] {
        stateLock.withLock { receivers }
    }
}
