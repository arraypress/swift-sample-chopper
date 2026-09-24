//
//  Onsets.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Where the hits are: spectral flux — the positive change of a log
//  magnitude spectrum frame to frame — peak-picked against a local mean,
//  with a minimum gap. Standard, transparent, and tuned on real stems.
//

import Accelerate
import Foundation

public enum OnsetDetector {

    public struct Options: Sendable {
        public var frame = 2048
        public var hop = 512
        /// How far above the local mean flux a peak must rise (in the flux's own units).
        public var delta: Float = 0.05
        /// Frames either side for the local mean and the local maximum.
        public var meanWindow = 12
        public var peakWindow = 2
        /// Two onsets closer than this are one.
        public var minimumGap = 0.05
        public init() {}
    }

    /// Onset times in seconds for mono samples at `sampleRate`: the flux peak's frame, centred,
    /// then refined to the attack itself — the first millisecond in ±30 ms whose RMS reaches a
    /// fifth of the local maximum — so a cut lands where the hit starts, not where a 43 ms window
    /// first noticed it.
    public static func detect(_ mono: [Float], sampleRate: Double, options: Options = Options()) -> [Double] {
        let n = options.frame, hop = options.hop
        guard mono.count > n * 2 else { return [] }
        let padded = [Float](repeating: 0, count: n / 2) + mono + [Float](repeating: 0, count: n / 2)
        let frames = (padded.count - n) / hop + 1
        let bins = n / 2 + 1
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else { return [] }
        defer { vDSP_DFT_DestroySetup(setup) }
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        var inRe = [Float](repeating: 0, count: n), outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        let inIm = [Float](repeating: 0, count: n)
        var previous = [Float](repeating: 0, count: bins)
        var current = [Float](repeating: 0, count: bins)
        var flux = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let start = f * hop
            vDSP_vmul(Array(padded[start..<(start + n)]), 1, window, 1, &inRe, 1, vDSP_Length(n))
            vDSP_DFT_Execute(setup, inRe, inIm, &outRe, &outIm)
            var sum: Float = 0
            for b in 0..<bins {
                let mag = log(1 + 10 * (outRe[b] * outRe[b] + outIm[b] * outIm[b]).squareRoot())
                current[b] = mag
                let d = mag - previous[b]
                if d > 0 { sum += d }
            }
            flux[f] = sum / Float(bins)
            swap(&previous, &current)
        }
        // peak picking
        var onsets: [Double] = []
        var last = -Double.infinity
        for f in 1..<frames {
            let lo = max(0, f - options.meanWindow), hi = min(frames - 1, f + options.meanWindow)
            var mean: Float = 0
            for k in lo...hi { mean += flux[k] }
            mean /= Float(hi - lo + 1)
            guard flux[f] >= mean + options.delta else { continue }
            var isPeak = true
            for k in max(0, f - options.peakWindow)...min(frames - 1, f + options.peakWindow) where k != f && flux[k] > flux[f] { isPeak = false; break }
            guard isPeak else { continue }
            let time = refine(Double(f * hop) / sampleRate, in: mono, sampleRate: sampleRate)
            if time - last >= options.minimumGap { onsets.append(time); last = time }
        }
        return onsets
    }

    /// The attack nearest `time`: 1 ms RMS windows over ±30 ms, the first one reaching 20% of the peak window.
    static func refine(_ time: Double, in mono: [Float], sampleRate: Double) -> Double {
        let win = max(8, Int(0.001 * sampleRate))
        let lo = max(0, Int((time - 0.03) * sampleRate)), hi = min(mono.count - win, Int((time + 0.03) * sampleRate))
        guard hi > lo else { return time }
        var levels: [Float] = []
        var k = lo
        while k + win <= hi { var s: Float = 0; for i in k..<(k + win) { s += mono[i] * mono[i] }; levels.append(s); k += win }
        guard let peak = levels.max(), peak > 0 else { return time }
        let first = levels.firstIndex { $0 >= 0.2 * peak } ?? 0
        return Double(lo + first * win) / sampleRate
    }
}
