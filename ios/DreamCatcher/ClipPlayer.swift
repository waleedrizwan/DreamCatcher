import AVFoundation
import SnoreAudio

/// Plays a snore clip through the speaker with the room's steady noise (hiss,
/// fans) gated out, normalized so its peak sits near full scale. Clips are stored at raw mic level (AGC off, mode .measurement),
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

    /// Bumped on every play/stop, so a slow denoise that finishes after the
    /// user tapped another clip (or stop) doesn't start playing.
    private var generation = 0

    func play(url: URL) async throws {
        generation += 1
        let mine = generation
        node.stop()
        let buffer = try await Task.detached(priority: .userInitiated) {
            try Self.load(url)
        }.value
        guard let buffer, mine == generation else { return }
        let format = buffer.format

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
        generation += 1
        node.stop()
        engine.stop()
    }

    private nonisolated static func load(_ url: URL) throws -> AVAudioPCMBuffer? {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try file.read(into: buffer)
        // Gate before normalizing: the gain below would otherwise turn the
        // hiss up as much as the snores.
        if let samples = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            let clean = ClipDenoiser.denoise(Array(UnsafeBufferPointer(start: samples, count: n)))
            clean.withUnsafeBufferPointer { samples.update(from: $0.baseAddress!, count: n) }
        }
        normalize(buffer)
        return buffer
    }

    private nonisolated static func normalize(_ buffer: AVAudioPCMBuffer) {
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
