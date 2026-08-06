//
//  SwitcherManager.swift
//  DualCast Switcher
//
//  Main-actor state owner: discovery, slot assignments, relay engine
//  lifecycle, hotkey bindings, and automatic reconnect when an assigned
//  source disappears and returns.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class SwitcherManager {
    // MARK: - Persisted configuration

    private enum DefaultsKey {
        static let slotA = "switcher.slotA"
        static let slotB = "switcher.slotB"
        static let outputName = "switcher.outputName"
    }

    var slotSourceNames: [String] {
        didSet {
            UserDefaults.standard.set(slotSourceNames[0], forKey: DefaultsKey.slotA)
            UserDefaults.standard.set(slotSourceNames[1], forKey: DefaultsKey.slotB)
        }
    }

    var outputName: String {
        didSet { UserDefaults.standard.set(outputName, forKey: DefaultsKey.outputName) }
    }

    // MARK: - Published state

    private(set) var discoveredSources: [NDISourceInfo] = []
    private(set) var isRunning = false
    private(set) var activeSlot = 0
    private(set) var previews: [Int: CGImage] = [:]
    private(set) var slotStats: [Int: RelayEngine.SlotStats] = [:]
    private(set) var slotStatuses: [Int: NDIReceiver.Status] = [:]
    private(set) var outputReceivers = 0
    private(set) var outputOnProgram = false
    private(set) var outputOnPreview = false
    private(set) var slotAudioAlive: [Int: Bool] = [:]
    private(set) var ndiAvailable = false
    private(set) var ndiVersion = ""
    var errorMessage: String?

    // MARK: - Internals

    private let finder = NDIFinder()
    private let hotkeys = GlobalHotKey()
    private var engine: RelayEngine?
    private var finderStarted = false
    private var statusPollTask: Task<Void, Never>?
    private var reconnectTasks: [Int: Task<Void, Never>] = [:]
    /// Set by bootstrap when both slots are assigned: keeps retrying start()
    /// as discovery results arrive (sources can take a few seconds to appear).
    private var autoStartWanted = false

    /// Hotkey labels shown in the UI (and mirrored in Stream Deck setup).
    static let hotkeyLabels = ["⌃⌥⌘1", "⌃⌥⌘2"]
    static let toggleHotkeyLabel = "⌃⌥⌘3"

    init() {
        let defaults = UserDefaults.standard
        slotSourceNames = [
            defaults.string(forKey: DefaultsKey.slotA) ?? "",
            defaults.string(forKey: DefaultsKey.slotB) ?? ""
        ]
        outputName = defaults.string(forKey: DefaultsKey.outputName) ?? "DualCast Active Display"
        registerHotkeys()
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        ndiAvailable = NDILibrary.isAvailable
        ndiVersion = NDILibrary.version
        guard ndiAvailable else {
            errorMessage = "libndi is not available on this Mac."
            return
        }

        if !finderStarted {
            finderStarted = true
            finder.onSourcesChanged = { [weak self] sources in
                self?.handleSourcesChanged(sources)
            }
            finder.start()
        }

        // Auto-start when both slots already have assignments; discovery may
        // not have found the sources yet, so retry on each source-list change.
        if !isRunning, bothSlotsAssigned {
            autoStartWanted = true
            await start()
        }
    }

    var bothSlotsAssigned: Bool {
        slotSourceNames.allSatisfy { !$0.isEmpty }
    }

    // MARK: - Engine lifecycle

    func start() async {
        guard !isRunning else { return }
        guard bothSlotsAssigned else {
            errorMessage = "Assign a source to both slots first."
            return
        }

        var slots: [Int: NDISourceInfo] = [:]
        for slot in 0..<RelayEngine.slotCount {
            let wanted = slotSourceNames[slot]
            guard let match = discoveredSources.first(where: { $0.name == wanted }) else {
                errorMessage = "Source not found: \(wanted). Start DualCast on the sending Mac, then try again."
                return
            }
            slots[slot] = match
        }

        let engine = RelayEngine()
        wireEngineCallbacks(engine)

        do {
            try engine.start(outputName: outputName, slots: slots)
            self.engine = engine
            isRunning = true
            autoStartWanted = false
            errorMessage = nil
            startStatusPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        autoStartWanted = false
        statusPollTask?.cancel()
        statusPollTask = nil
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()

        if let engine {
            await engine.stop()
        }
        engine = nil
        isRunning = false
        outputReceivers = 0
        outputOnProgram = false
        outputOnPreview = false
        slotStatuses = [:]
    }

    // MARK: - Switching

    func selectSlot(_ slot: Int) {
        engine?.setActiveSlot(slot)
    }

    func toggleSlot() {
        engine?.toggleSlot()
    }

    // MARK: - Engine callbacks

    private func wireEngineCallbacks(_ engine: RelayEngine) {
        engine.onActiveSlotChanged = { [weak self] slot in
            self?.activeSlot = slot
        }
        engine.onPreview = { [weak self] slot, image in
            self?.previews[slot] = image
        }
        engine.onSlotStats = { [weak self] slot, stats in
            self?.slotStats[slot] = stats
        }
        engine.onReceiverStatus = { [weak self] slot, status in
            self?.handleReceiverStatus(slot: slot, status: status)
        }
    }

    private func handleReceiverStatus(slot: Int, status: NDIReceiver.Status) {
        slotStatuses[slot] = status
        guard isRunning, case .failed = status else { return }
        scheduleReconnect(for: slot)
    }

    // MARK: - Reconnect

    /// After a failure (or when discovery sees a vanished source return),
    /// reconnect that slot if it's still wanted.
    private func scheduleReconnect(for slot: Int, delay: Duration = .seconds(3)) {
        guard reconnectTasks[slot] == nil else { return }
        reconnectTasks[slot] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTasks[slot] = nil
            self.attemptReconnect(for: slot)
        }
    }

    private func attemptReconnect(for slot: Int) {
        guard isRunning, let engine else { return }
        let wanted = slotSourceNames[slot]
        guard !wanted.isEmpty,
              let match = discoveredSources.first(where: { $0.name == wanted }) else { return }
        // Skip if the slot is already healthy.
        if case .receiving = slotStatuses[slot] { return }
        engine.attach(slot: slot, source: match)
    }

    // MARK: - Discovery

    private func handleSourcesChanged(_ sources: [NDISourceInfo]) {
        discoveredSources = sources
        if !isRunning {
            if autoStartWanted {
                Task { await start() }
            }
            return
        }
        // If a wanted source (re)appeared and its slot is unhealthy, reconnect.
        for slot in 0..<RelayEngine.slotCount {
            attemptReconnect(for: slot)
        }
    }

    // MARK: - Output status polling

    private func startStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.engine else { return }
                let status = await Task.detached {
                    (
                        engine.outputConnectionCount,
                        engine.outputTally,
                        engine.audioAlive(for: 0),
                        engine.audioAlive(for: 1)
                    )
                }.value
                self.outputReceivers = status.0
                self.outputOnProgram = status.1.onProgram
                self.outputOnPreview = status.1.onPreview
                self.slotAudioAlive[0] = status.2
                self.slotAudioAlive[1] = status.3
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        // ⌃⌥⌘1 → slot A, ⌃⌥⌘2 → slot B, ⌃⌥⌘3 → toggle.
        // Stream Deck setup: two "Hotkey" actions with these same keystrokes.
        hotkeys.register(GlobalHotKey.Binding(
            id: 1,
            keyCode: UInt32(kVK_ANSI_1),
            modifiers: GlobalHotKey.switcherModifiers
        ) { [weak self] in
            self?.selectSlot(0)
        })
        hotkeys.register(GlobalHotKey.Binding(
            id: 2,
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: GlobalHotKey.switcherModifiers
        ) { [weak self] in
            self?.selectSlot(1)
        })
        hotkeys.register(GlobalHotKey.Binding(
            id: 3,
            keyCode: UInt32(kVK_ANSI_3),
            modifiers: GlobalHotKey.switcherModifiers
        ) { [weak self] in
            self?.toggleSlot()
        })
    }
}
