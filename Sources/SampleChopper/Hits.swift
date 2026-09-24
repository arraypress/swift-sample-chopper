//
//  Hits.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  One-shots from a percussive stem: each onset cut from just before its
//  attack to where it has decayed or the next hit begins, scored for how
//  clean it is (how quiet its tail is against its peak, and whether another
//  hit sits inside it), fingerprinted so near-identical hits are counted
//  once, and named with CLAP against a short list of drum words.
//

import Foundation
import SampleSearch

public struct Hit: Sendable {
    public let onset: Double
    /// Sample range in the stem.
    public let range: Range<Int>
    public let peakDB: Float
    /// The tail's RMS relative to the peak, in dB: more negative is cleaner.
    public let tailDB: Float
    /// No other onset inside the cut.
    public let isolated: Bool
    /// A 24-value spectral fingerprint of the attack, for de-duplication.
    public let fingerprint: [Float]
    public var seconds: Double { Double(range.count) }

    public var cleanliness: Float { (isolated ? 0 : -12) - tailDB }
}

public enum HitCutter {

    public struct Options: Sendable {
        public var preRoll = 0.004
        public var maximum = 1.5
        /// The decay, relative to the peak, at which a hit is over.
        public var decayDB: Float = -48
        public var fadeIn = 0.001
        public var fadeOut = 0.008
        public init() {}
    }

    /// Hits for every onset of a stem.
    public static func cut(_ stem: StemAudio, onsets: [Double], options: Options = Options()) -> [Hit] {
        var hits: [Hit] = []
        let sr = stem.sampleRate
        for (i, onset) in onsets.enumerated() {
            let start = stem.zeroCrossing(near: max(0, onset - options.preRoll))
            let next = i + 1 < onsets.count ? onsets[i + 1] : stem.seconds
            let hardEnd = min(stem.count, Int(min(next - 0.002, onset + options.maximum) * sr))
            guard hardEnd > start + Int(0.02 * sr) else { continue }
            // decay: 5 ms RMS windows after the peak
            let region = stem.mono[start..<hardEnd]
            let peak = StemAudio.peak(Array(region))
            guard peak > 1e-4 else { continue }
            let win = Int(0.005 * sr)
            var end = hardEnd
            var k = start + Int(0.01 * sr)
            var quiet = 0
            while k + win <= hardEnd {
                let r = StemAudio.rms(stem.mono[k..<(k + win)])
                if StemAudio.dB(r / peak) < options.decayDB { quiet += 1; if quiet >= 2 { end = k + win; break } } else { quiet = 0 }
                k += win
            }
            end = stem.zeroCrossing(near: Double(end) / sr, within: 0.002)
            guard end > start + Int(0.01 * sr) else { continue }
            let tailStart = max(start, end - Int(0.03 * sr))
            let tail = StemAudio.rms(stem.mono[tailStart..<end])
            let isolated = i + 1 >= onsets.count || onsets[i + 1] >= Double(end) / sr - 0.002
            hits.append(Hit(onset: onset, range: start..<end, peakDB: StemAudio.dB(peak), tailDB: StemAudio.dB(tail / peak), isolated: isolated,
                            fingerprint: fingerprint(stem.mono[start..<min(end, start + Int(0.064 * sr))], sampleRate: sr)))
        }
        return hits
    }

    /// 24 log-spaced band energies of the first 64 ms, normalised to unit length.
    static func fingerprint(_ samples: ArraySlice<Float>, sampleRate: Double) -> [Float] {
        let n = 2048
        var x = Array(samples.prefix(n)); x += [Float](repeating: 0, count: max(0, n - x.count))
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        for k in 0..<(n / 2) {           // a plain DFT on 2048 points is fine here: a few hundred hits
            var sr: Float = 0, si: Float = 0
            let w = -2 * Float.pi * Float(k) / Float(n)
            var j = 0
            while j < n { let a = w * Float(j); sr += x[j] * cos(a); si += x[j] * sin(a); j += 2 }   // every other sample: enough for bands
            re[k] = sr; im[k] = si
        }
        let bands = 24
        var out = [Float](repeating: 0, count: bands)
        let fMin = 30.0, fMax = min(16_000.0, sampleRate / 2)
        for b in 0..<bands {
            let lo = fMin * pow(fMax / fMin, Double(b) / Double(bands)), hi = fMin * pow(fMax / fMin, Double(b + 1) / Double(bands))
            let kLo = Int(lo / sampleRate * Double(n)), kHi = max(Int(lo / sampleRate * Double(n)) + 1, Int(hi / sampleRate * Double(n)))
            var e: Float = 0
            for k in kLo..<min(n / 2, kHi) { e += re[k] * re[k] + im[k] * im[k] }
            out[b] = log(1 + e)
        }
        let norm = out.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? out.map { $0 / norm } : out
    }

    public static func similarity(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    /// Groups of near-identical hits (fingerprint cosine ≥ `threshold`), each led by its cleanest member.
    public static func groups(_ hits: [Hit], threshold: Float = 0.97) -> [[Hit]] {
        var groups: [[Hit]] = []
        for hit in hits.sorted(by: { $0.cleanliness > $1.cleanliness }) {
            if let i = groups.firstIndex(where: { similarity($0[0].fingerprint, hit.fingerprint) >= threshold }) { groups[i].append(hit) } else { groups.append([hit]) }
        }
        return groups
    }
}

/// CLAP zero-shot over drum words.
public struct HitNamer: Sendable {

    public static let labels: [(name: String, phrase: String)] = [
        ("kick", "a kick drum hit"), ("snare", "a snare drum hit"), ("clap", "a hand clap"), ("hat", "a closed hi-hat"),
        ("open-hat", "an open hi-hat"), ("tom", "a tom drum hit"), ("crash", "a crash cymbal"), ("ride", "a ride cymbal"),
        ("perc", "a percussion hit"), ("fx", "a sound effect"),
    ]

    let embedder: ClapEmbedder
    let vectors: [(name: String, embedding: [Float])]

    public init(embedder: ClapEmbedder) async throws {
        self.embedder = embedder
        var v: [(String, [Float])] = []
        for l in Self.labels { v.append((l.name, try await embedder.embed(text: l.phrase))) }
        vectors = v
    }

    /// The best label and its cosine for a hit's samples (any rate; resampled to 48 kHz).
    public func name(_ samples: [Float], sampleRate: Double) async throws -> (label: String, score: Float, probability: Float) {
        let s48 = sampleRate == 48_000 ? samples : MusicTranscriberResampler.resample(samples, from: sampleRate, to: 48_000)
        let e = try await embedder.embed(samples48k: Array(s48.prefix(ClapFrontEnd.windowSamples)))
        let tags = SampleIndex.tags(for: e, labels: vectors, logitScale: embedder.logitScale)
        return (tags[0].label, tags[0].score, tags[0].probability)
    }
}
