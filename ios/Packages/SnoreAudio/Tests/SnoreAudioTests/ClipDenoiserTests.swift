import AVFoundation
import XCTest
@testable import SnoreAudio

final class ClipDenoiserTests: XCTestCase {

    private func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot()
    }

    private func db(_ ratio: Float) -> Float { 20 * log10(ratio) }

    /// 12 s of steady hiss with a 150 Hz "snore" every 4 s: the hiss between
    /// snores drops a lot, the snores themselves barely change.
    func testHissGoesSnoresStay() {
        let sr = 16_000, n = 12 * sr
        var rng = SystemRandomNumberGenerator()
        var x = (0..<n).map { _ in Float.random(in: -0.01...0.01, using: &rng) }
        var snore = [Bool](repeating: false, count: n)
        for start in stride(from: 1 * sr, to: n, by: 4 * sr) {
            for i in start..<min(start + sr, n) {
                x[i] += 0.1 * sin(2 * .pi * 150 * Float(i) / Float(sr))
                snore[i] = true
            }
        }
        let y = ClipDenoiser.denoise(x)
        XCTAssertEqual(y.count, x.count)

        // Middles only, away from the gate's ramps.
        let quiet = (2 * sr + sr / 2)..<(4 * sr + sr / 2)
        let loud = (5 * sr + sr / 4)..<(6 * sr - sr / 4)
        XCTAssertFalse(snore[quiet.lowerBound]); XCTAssertTrue(snore[loud.lowerBound])

        let hissDrop = db(rms(y[quiet]) / rms(x[quiet]))
        let snoreChange = db(rms(y[loud]) / rms(x[loud]))
        XCTAssertLessThan(hissDrop, -12, "hiss only fell \(hissDrop) dB")
        XCTAssertLessThan(abs(snoreChange), 1.5, "snore changed \(snoreChange) dB")
    }

    func testShortInputPassesThrough() {
        let x: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(ClipDenoiser.denoise(x), x)
    }

    /// Real clip, when pointed at one (16 kHz mono):
    ///   CLIP_DENOISE_IN=in.wav CLIP_DENOISE_OUT=out.wav xcodebuild … test
    func testRealClip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inPath = env["CLIP_DENOISE_IN"], let outPath = env["CLIP_DENOISE_OUT"] else {
            throw XCTSkip("CLIP_DENOISE_IN / CLIP_DENOISE_OUT not set")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: inPath))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let x = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                          count: Int(buffer.frameLength)))
        let y = ClipDenoiser.denoise(x)
        let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: AVAudioFrameCount(y.count))!
        out.frameLength = AVAudioFrameCount(y.count)
        y.withUnsafeBufferPointer { out.floatChannelData![0].update(from: $0.baseAddress!, count: y.count) }
        let writer = try AVAudioFile(forWriting: URL(fileURLWithPath: outPath),
                                     settings: file.fileFormat.settings)
        try writer.write(from: out)
    }
}
