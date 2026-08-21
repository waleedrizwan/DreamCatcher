import Foundation

/// Holds a background-execution assertion (design-ios §2.3): an interruption
/// that ends while the app is backgrounded gives us only seconds of runtime
/// unless one of these is held. ~30 s is guaranteed; the resume retry ladder
/// must fit inside it. Built on `performExpiringActivity` rather than
/// `UIApplication.beginBackgroundTask` so it is callable from any executor.
public final class BackgroundAssertion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    public init(name: String) {
        ProcessInfo.processInfo.performExpiringActivity(withReason: name) {
            [semaphore] expired in
            guard !expired else { return }
            // Hold the assertion until end() — bounded so an abandoned
            // assertion can never pin the process.
            _ = semaphore.wait(timeout: .now() + 35)
        }
    }

    public func end() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        semaphore.signal()
    }

    deinit { end() }
}

/// Free-disk probe for the storage-full degrade ladder (spec §3.1 / plan M3):
/// clips stop first, then the session finalizes gracefully — metrics writes
/// are the last thing to give up.
public enum DiskSpace {
    /// Bytes the app may still use without evicting anything.
    public static func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    public static let preFlightMinBytes: Int64 = 200 * 1_048_576  // warn below
    public static let clipCutoffBytes: Int64 = 50 * 1_048_576     // drop clips
    public static let criticalBytes: Int64 = 15 * 1_048_576       // finalize
}
