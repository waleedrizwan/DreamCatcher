import Accelerate

/// Gates the room's steady noise (mic hiss, fans, air purifiers) out of a clip
/// for listening. Playback only: detection and the stored file never see it.
///
/// Per frequency bin of a 1024-point STFT (64 ms at 16 kHz, hop 256):
///
///     noise[f]   = 20th percentile of |STFT| over the clip (snores come and go; a fan never stops)
///     mask[t, f] = soft step from 0 to 1 as |STFT| rises from 2.5x to 4x noise[f]
///
/// The mask is smoothed over 3 frames and 5 bins and floored at −24 dB, so the
/// room is turned down rather than cut to dead silence. NightOwl's
/// Denoise.swift gate, with the thresholds raised from 1.5x/3x: a clip is only
/// 12 s, and at the old ones steady white noise still leaked through (−7 dB,
/// not −13 dB; ClipDenoiserTests).
public enum ClipDenoiser {
    static let nFFT = 1024, hop = 256, log2n: vDSP_Length = 10
    static let bins = nFFT / 2 + 1
    static let noisePercentile: Float = 0.20
    static let gateLo: Float = 2.5, gateHi: Float = 4.0
    static let floor = Float(pow(10.0, -24.0 / 20))

    /// Periodic Hann window.
    static let window: [Float] = (0..<nFFT).map {
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT)))
    }

    /// `x` with the steady background removed, same length.
    public static func denoise(_ x: [Float]) -> [Float] {
        guard x.count >= nFFT else { return x }
        let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(fft) }

        // STFT of x, reflect-padded by half a window at each end.
        let pad = nFFT / 2
        func sample(_ i: Int) -> Float {
            var j = i - pad
            if j < 0 { j = -j }
            if j >= x.count { j = 2 * (x.count - 1) - j }
            return x[min(max(j, 0), x.count - 1)]
        }
        let T = 1 + x.count / hop
        var re = [[Float]](), im = [[Float]](), mag = [[Float]]()
        re.reserveCapacity(T); im.reserveCapacity(T); mag.reserveCapacity(T)
        var frame = [Float](repeating: 0, count: nFFT)
        for t in 0..<T {
            for i in 0..<nFFT { frame[i] = sample(t * hop + i) * window[i] }
            let (r, m) = forward(fft, frame)
            re.append(r); im.append(m)
            mag.append((0..<bins).map { (r[$0] * r[$0] + m[$0] * m[$0]).squareRoot() })
        }

        // Noise floor per bin.
        let rank = Int(noisePercentile * Float(T - 1))
        let noise: [Float] = (0..<bins).map { k in
            max((0..<T).map { mag[$0][k] }.sorted()[rank], 1e-12)
        }

        // Soft gate, smoothed 3 frames x 5 bins.
        let raw: [[Float]] = mag.map { row in
            (0..<bins).map { k in
                min(max((row[k] / noise[k] - gateLo) / (gateHi - gateLo), 0), 1)
            }
        }
        var out = [Float](repeating: 0, count: hop * (T - 1) + nFFT)
        var norm = [Float](repeating: 0, count: out.count)
        for t in 0..<T {
            let a = raw[max(t - 1, 0)], b = raw[t], c = raw[min(t + 1, T - 1)]
            let s = (0..<bins).map { (a[$0] + b[$0] + c[$0]) / 3 }
            var r = re[t], m = im[t]
            for k in 0..<bins {
                var sum: Float = 0
                for d in -2...2 { sum += s[min(max(k + d, 0), bins - 1)] }
                let g = max(sum / 5, floor)
                r[k] *= g; m[k] *= g
            }
            let y = inverse(fft, r, m)
            for i in 0..<nFFT {
                out[t * hop + i] += y[i] * window[i]
                norm[t * hop + i] += window[i] * window[i]
            }
        }
        return (0..<x.count).map { j in out[pad + j] / max(norm[pad + j], 1e-8) }
    }

    /// Bins 0...512 of a 1024-point real FFT (vDSP scaling: 2x numpy).
    private static func forward(_ setup: FFTSetup, _ x: [Float]) -> ([Float], [Float]) {
        var r = [Float](repeating: 0, count: nFFT / 2), m = r
        r.withUnsafeMutableBufferPointer { rp in
            m.withUnsafeMutableBufferPointer { mp in
                var s = DSPSplitComplex(realp: rp.baseAddress!, imagp: mp.baseAddress!)
                x.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &s, 1,
                              vDSP_Length(nFFT / 2))
                }
                vDSP_fft_zrip(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        // DC and Nyquist are packed together in bin 0.
        var outR = [Float](repeating: 0, count: bins), outI = outR
        outR[0] = r[0]; outR[nFFT / 2] = m[0]
        for k in 1..<nFFT / 2 { outR[k] = r[k]; outI[k] = m[k] }
        return (outR, outI)
    }

    /// Inverse of `forward`.
    private static func inverse(_ setup: FFTSetup, _ inR: [Float], _ inI: [Float]) -> [Float] {
        var r = Array(inR[0..<nFFT / 2]), m = Array(inI[0..<nFFT / 2])
        m[0] = inR[nFFT / 2]
        var y = [Float](repeating: 0, count: nFFT)
        r.withUnsafeMutableBufferPointer { rp in
            m.withUnsafeMutableBufferPointer { mp in
                var s = DSPSplitComplex(realp: rp.baseAddress!, imagp: mp.baseAddress!)
                vDSP_fft_zrip(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                y.withUnsafeMutableBytes {
                    vDSP_ztoc(&s, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              vDSP_Length(nFFT / 2))
                }
            }
        }
        // A vDSP forward + inverse round trip scales by 2n.
        return vDSP.multiply(1 / Float(2 * nFFT), y)
    }
}
