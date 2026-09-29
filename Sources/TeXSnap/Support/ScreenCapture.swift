import AppKit

enum ScreenCapture {
    /// Lets the user drag out a region with the system screenshot interface (Space switches to window
    /// selection, Esc cancels). Returns PNG data, or nil when cancelled.
    static func captureRegion() async -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("texsnap-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-o", url.path]
        let waiter = ExitWaiter(process)
        do {
            try process.run()
        } catch {
            return nil
        }
        _ = await waiter.wait()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }
}

/// Child processes to stop when TeXSnap quits.
final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) {
        lock.lock()
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let running = Array(processes.values)
        lock.unlock()
        running.filter(\.isRunning).forEach { $0.terminate() }
    }
}
