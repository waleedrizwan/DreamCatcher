import AVFoundation

/// Plays a snore clip through the speaker, normalized so its peak sits near
/// full scale. Clips are stored at raw mic level (AGC off, mode .measurement),
/// often −40 dBFS or quieter, which is close to inaudible played back as is.
@MainActor
final class ClipPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    /// Peak target after normalization, and the most gain we'll apply (+40 dB)
    /// so a near-silent clip doesn't become a wall of hiss.
    private static let targetPeak: Float = 0.9
    private static let maxGain: Float = 100

    init() {
        engine.attach(node)
    }

    func play(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { return }
        try file.read(into: buffer)
        Self.normalize(buffer)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.scheduleBuffer(buffer, at: nil, options: .interrupts,
                            completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.engine.stop() }
        }
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
    }

    private static func normalize(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var peak: Float = 0
        for c in 0..<channelCount {
            for i in 0..<frames { peak = max(peak, abs(channels[c][i])) }
        }
        guard peak > 0 else { return }
        let gain = min(targetPeak / peak, maxGain)
        guard gain > 1 else { return }
        for c in 0..<channelCount {
            for i in 0..<frames { channels[c][i] *= gain }
        }
    }
}
