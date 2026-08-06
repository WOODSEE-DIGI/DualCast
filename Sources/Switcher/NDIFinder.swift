//
//  NDIFinder.swift
//  DualCast Switcher
//
//  Discovers NDI sources on the network (mDNS) and publishes the list to
//  the UI whenever it changes. Runs its blocking NDIlib_find_wait_for_sources
//  poll on a dedicated thread; the finder instance is only ever touched
//  from that thread after creation.
//

import Foundation

/// A discovered NDI source, with strings copied out of NDI-owned memory.
struct NDISourceInfo: Sendable, Hashable {
    /// Full NDI name, e.g. "SHOOTYS-MAC-STUDIO.LOCAL (DualCast Studio Display)".
    var name: String
    /// "ip:port" of the source (may be empty for some discovery paths).
    var urlAddress: String

    /// The parenthesised source part, e.g. "DualCast Studio Display".
    var shortName: String {
        guard let open = name.lastIndex(of: "("),
              let close = name.lastIndex(of: ")"), open < close else { return name }
        return String(name[name.index(after: open)..<close])
    }
}

final class NDIFinder: @unchecked Sendable {
    var onSourcesChanged: (@MainActor ([NDISourceInfo]) -> Void)?

    private var finder: NDIlib_find_instance_t?
    private var running = false
    private let lock = NSLock()

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard finder == nil else { return }

        var create = NDIlib_find_create_t(
            show_local_sources: true,
            p_groups: nil,
            extra_ips: nil
        )
        finder = NDIlib_find_create_v2(&create)
        guard finder != nil else { return }

        running = true
        Thread.detachNewThread { [weak self] in
            self?.pollLoop()
        }
    }

    /// Signals the poll loop to exit; the finder is destroyed on the poll
    /// thread once the current wait expires (≤ 2 s later).
    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func pollLoop() {
        lock.lock()
        let instance = finder
        lock.unlock()
        guard let instance else { return }

        // Publish the initial (usually empty) list immediately.
        publish(from: instance)

        while true {
            lock.lock()
            let shouldContinue = running
            lock.unlock()
            guard shouldContinue else { break }

            if NDIlib_find_wait_for_sources(instance, 2000) {
                publish(from: instance)
            }
        }

        NDIlib_find_destroy(instance)
        lock.lock()
        finder = nil
        lock.unlock()
    }

    private func publish(from instance: NDIlib_find_instance_t) {
        var count: UInt32 = 0
        guard let pointer = NDIlib_find_get_current_sources(instance, &count) else { return }

        let buffer = UnsafeBufferPointer(start: pointer, count: Int(count))
        var sources: [NDISourceInfo] = []
        sources.reserveCapacity(Int(count))
        for raw in buffer {
            guard let namePointer = raw.p_ndi_name else { continue }
            let name = String(cString: namePointer)
            let url = raw.p_url_address.map { String(cString: $0) } ?? ""
            sources.append(NDISourceInfo(name: name, urlAddress: url))
        }

        for source in sources {
            NSLog("[Switcher] found source: %@ url: %@", source.name, source.urlAddress)
        }

        let callback = onSourcesChanged
        Task { @MainActor in
            callback?(sources.sorted { $0.name < $1.name })
        }
    }
}
