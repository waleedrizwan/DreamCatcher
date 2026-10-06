import AVFoundation

/// AVAudioSession configuration + interruption/route plumbing (design-ios §2).
/// Category `.playAndRecord`, mode `.measurement` (AGC off — the relative-dB
/// intensity model depends on it), `.mixWithOthers`, built-in mic pinned.
public final class AudioSessionCoordinator: @unchecked Sendable {

    public enum SessionEvent: Sendable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged
        case mediaServicesReset
        /// The engine's input format changed underneath us (design-ios §2.4).
        case configurationChanged
    }

    private var observers: [NSObjectProtocol] = []
    private var onEvent: (@Sendable (SessionEvent) -> Void)?

    public init() {}

    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.mixWithOthers, .allowBluetoothA2DP])
        try session.setActive(true)
        try pinBuiltInMic()
        try? session.setPreferredIOBufferDuration(0.1)
    }

    /// Never record through AirPods sitting in their case (design-ios §2.1);
    /// re-asserted on every route change.
    public func pinBuiltInMic() throws {
        let session = AVAudioSession.sharedInstance()
        if let builtIn = session.availableInputs?
            .first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
        }
    }

    public func deactivate() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func startObserving(_ handler: @escaping @Sendable (SessionEvent) -> Void) {
        onEvent = handler
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil,
            queue: nil) { [weak self] note in
                guard let info = note.userInfo,
                      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                switch type {
                case .began:
                    self?.onEvent?(.interruptionBegan)
                case .ended:
                    let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    self?.onEvent?(.interruptionEnded(
                        shouldResume: opts.contains(.shouldResume)))
                @unknown default:
                    break
                }
            })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil,
            queue: nil) { [weak self] _ in
                try? self?.pinBuiltInMic()
                self?.onEvent?(.routeChanged)
            })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
            queue: nil) { [weak self] _ in
                self?.onEvent?(.mediaServicesReset)
            })
    }

    public func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        onEvent = nil
    }
}
