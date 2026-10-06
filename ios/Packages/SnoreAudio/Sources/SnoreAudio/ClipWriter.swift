import AVFoundation

/// Encodes a PCM snapshot to AAC-LC mono 16 kHz 32 kbps .m4a (spec §4).
public enum ClipWriter {

    public struct Written: Sendable {
        public var url: URL
        public var bytes: Int64
        public var durationMs: Int64
    }

    public static func write(samples: [Int16], to url: URL) throws -> Written {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 16_000, channels: 1,
                                   interleaved: true)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.int16ChannelData![0].update(from: src.baseAddress!,
                                               count: samples.count)
        }
        try file.write(from: buffer)
        // Clips are written while the phone is locked all night, so they must
        // not carry NSFileProtectionComplete (design-ios §4).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return Written(url: url, bytes: bytes,
                       durationMs: Int64(samples.count) * 1000 / 16_000)
    }
}
