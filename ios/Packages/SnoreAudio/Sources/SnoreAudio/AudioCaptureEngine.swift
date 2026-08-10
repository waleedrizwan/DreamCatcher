import AVFoundation
import SnoreCore

/// AVAudioEngine capture: taps the input node at the HARDWARE format
/// (input taps cannot request 16 kHz — spec §0.1) and converts to
/// 16 kHz mono Float32 + Int16 for the ring buffer.
public final class AudioCaptureEngine: @unchecked Sendable {

    public struct Chunk: Sendable {
        public var floats: [Float]
        public var int16s: [Int16]
        /// Session sample time (16 kHz) of the first sample in this chunk.
        public var firstSampleIndex: Int64
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samplesDelivered: Int64 = 0
    private var onChunk: (@Sendable (Chunk) -> Void)?

    public private(set) var isRunning = false

    public init() {}

    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false)!

    /// `startingAtSampleIndex` lets the service keep one monotonic session
    /// sample clock across engine restarts (interruptions re-anchor tMs but
    /// the ring buffer keeps counting).
    public func start(startingAtSampleIndex: Int64 = 0,
                      onChunk: @escaping @Sendable (Chunk) -> Void) throws {
        self.onChunk = onChunk
        self.samplesDelivered = startingAtSampleIndex

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: hwFormat, to: Self.targetFormat)!
        self.converter = converter

        // ~100 ms buffers: fewer wakeups, better battery (design-ios §2.1).
        let bufferSize = AVAudioFrameCount(hwFormat.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) {
            [weak self] buffer, _ in
            self?.convertAndDeliver(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }

    /// Sample count delivered so far — the restart anchor.
    public var deliveredSampleIndex: Int64 { samplesDelivered }

    private func convertAndDeliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat,
                                         frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0,
              let channel = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        let floats = Array(UnsafeBufferPointer(start: channel, count: n))
        let int16s = floats.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }
        let chunk = Chunk(floats: floats, int16s: int16s,
                          firstSampleIndex: samplesDelivered)
        samplesDelivered += Int64(n)
        onChunk?(chunk)
    }
}
