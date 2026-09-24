//
//  PhraseFinder.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Whole musical phrases rather than fixed bars: a bar is described by its
//  chroma at every sixteenth (which pitch classes sound when), and a span
//  of P bars is a phrase when the P bars after it are the same span again.
//  The smallest P that repeats is the phrase length — an 8-bar melody whose
//  halves differ is 8, one made of two identical halves is 4. Phrases that
//  recur most are the song's main parts.
//

import Accelerate
import Foundation

public struct PhraseCandidate: Sendable {
    public let startBar: Int
    public let bars: Int
    public let range: Range<Int>
    public let start: Double
    /// Mean bar-to-bar similarity with the next repetition, 0…1.
    public let repeatScore: Float
    /// How many later spans of the song repeat this phrase (itself excluded).
    public let repeats: Int
    public let levelDB: Float
    public let descriptor: [Float]
}

public enum PhraseFinder {

    public struct Options: Sendable {
        /// Phrase lengths tried, shortest first.
        public var lengths = [4, 8, 16]
        /// A span repeats when the mean bar similarity with the next span reaches this.
        public var repeatThreshold: Float = 0.8
        /// Two phrases are the same when their descriptors' cosine reaches this.
        public var sameThreshold: Float = 0.9
        /// A longer span wins over a shorter one when it repeats this much better: a melody that
        /// changes over a repeating chord loop scores higher at its own length than at the chords'.
        public var longerWinsBy: Float = 0.02
        public var activeBelowLoudDB: Float = 12
        public var limit = 4
        public init() {}
    }

    static let steps = 16
    static let chromaBins = 12

    /// Chroma at every sixteenth of every bar: `[bar][step * 12 + pitchClass]`, each step unit-normalised, plus bar RMS in dB.
    static func barDescriptors(_ stem: StemAudio, grid: BarGrid) -> (descriptors: [[Float]], levels: [Float]) {
        let sr = stem.sampleRate
        let barSamples = Int((grid.barSeconds * sr).rounded())
        let stepSamples = barSamples / steps
        let n = 8192
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else { return ([], []) }
        defer { vDSP_DFT_DestroySetup(setup) }
        let window = (0..<stepSamples).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(stepSamples))) }
        // bin → pitch class, 55 Hz … 4 kHz
        var binClass = [Int](repeating: -1, count: n / 2)
        for b in 1..<(n / 2) {
            let f = Double(b) * sr / Double(n)
            guard f >= 55, f <= 4000 else { continue }
            binClass[b] = Int((12 * log2(f / 440) + 69).rounded()) % 12
            if binClass[b] < 0 { binClass[b] += 12 }
        }
        var inRe = [Float](repeating: 0, count: n), outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        let inIm = [Float](repeating: 0, count: n)
        var descriptors: [[Float]] = [], levels: [Float] = []
        for d in grid.downbeats {
            let start = Int((d * sr).rounded())
            guard start + barSamples <= stem.count else { break }
            var v = [Float](repeating: 0, count: steps * chromaBins)
            for s in 0..<steps {
                let a = start + s * stepSamples
                for i in 0..<n { inRe[i] = i < stepSamples ? stem.mono[a + i] * window[i] : 0 }
                vDSP_DFT_Execute(setup, inRe, inIm, &outRe, &outIm)
                var chroma = [Float](repeating: 0, count: chromaBins)
                for b in 1..<(n / 2) where binClass[b] >= 0 { chroma[binClass[b]] += outRe[b] * outRe[b] + outIm[b] * outIm[b] }
                for c in 0..<chromaBins { chroma[c] = chroma[c].squareRoot() }      // magnitude chroma: leakage stays small against the peaks
                let norm = chroma.reduce(0) { $0 + $1 * $1 }.squareRoot()
                for c in 0..<chromaBins { v[s * chromaBins + c] = norm > 0 ? chroma[c] / norm : 0 }
            }
            descriptors.append(v)
            levels.append(StemAudio.dB(StemAudio.rms(stem.mono[start..<(start + barSamples)])))
        }
        return (descriptors, levels)
    }

    /// Cosine of two bar descriptors: the mean over steps of the chroma cosine.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s / Float(steps)
    }

    /// Repeat scores per length at every bar, for looking at a track.
    public static func scores(_ stem: StemAudio, grid: BarGrid, lengths: [Int] = [4, 8, 16]) -> [[Int: Float]] {
        let (bars, _) = barDescriptors(stem, grid: grid)
        return (0..<bars.count).map { s in
            var d: [Int: Float] = [:]
            for p in lengths where s + 2 * p <= bars.count {
                var total: Float = 0
                for i in 0..<p { total += similarity(bars[s + i], bars[s + p + i]) }
                d[p] = total / Float(p)
            }
            return d
        }
    }

    /// Phrases of a stem, longest-recurring first.
    public static func find(_ stem: StemAudio, grid: BarGrid, options: Options = Options()) -> [PhraseCandidate] {
        let (bars, levels) = barDescriptors(stem, grid: grid)
        guard bars.count >= 4 else { return [] }
        let loud = levels.sorted()[Int(Double(levels.count - 1) * 0.9)]
        let active = levels.map { $0 >= loud - options.activeBelowLoudDB && $0 > -50 }
        let sr = stem.sampleRate
        func spanScore(_ s: Int, _ p: Int, against t: Int) -> Float {
            var total: Float = 0
            for i in 0..<p { total += similarity(bars[s + i], bars[t + i]) }
            return total / Float(p)
        }
        /// Repeat scores at every length for a start, for callers that want to look.
        func candidates(at s: Int) -> [(p: Int, score: Float)] {
            options.lengths.compactMap { p in
                guard s + 2 * p <= bars.count, (s..<(s + p)).allSatisfy({ active[$0] }) else { return nil }
                return (p, spanScore(s, p, against: s + p))
            }
        }
        var found: [PhraseCandidate] = []
        var s = 0
        while s < bars.count {
            var taken = false
            // the shortest span that repeats, unless a longer one repeats clearly better
            let scored = candidates(at: s).filter { $0.score >= options.repeatThreshold }
            if let best = scored.max(by: { $0.score < $1.score }), let choice = scored.first(where: { $0.score >= best.score - options.longerWinsBy }) {
                let p = choice.p, score = choice.score
                // how often this phrase comes back anywhere later
                var repeats = 0
                var t = s + p
                while t + p <= bars.count { if spanScore(s, p, against: t) >= options.repeatThreshold { repeats += 1 }; t += p }
                let range = Int((grid.downbeats[s] * sr).rounded())..<(Int((grid.downbeats[s] * sr).rounded()) + Int((Double(p) * grid.barSeconds * sr).rounded()))
                guard range.upperBound <= stem.count else { continue }
                let descriptor = (0..<p).flatMap { bars[s + $0] }
                found.append(PhraseCandidate(startBar: s, bars: p, range: range, start: grid.downbeats[s], repeatScore: score, repeats: repeats,
                                             levelDB: levels[s..<(s + p)].reduce(0, +) / Float(p), descriptor: descriptor))
                s += p; taken = true
            }
            if !taken { s += 1 }
        }
        // the same phrase found again later is the same phrase: keep the first, credit the repeats
        var kept: [PhraseCandidate] = []
        for c in found.sorted(by: { ($0.repeats, $0.levelDB) > ($1.repeats, $1.levelDB) }) {
            if kept.contains(where: { $0.bars == c.bars && zip($0.descriptor, c.descriptor).reduce(0) { $0 + $1.0 * $1.1 } / Float(steps * c.bars) >= options.sameThreshold }) { continue }
            kept.append(c)
            if kept.count >= options.limit { break }
        }
        return kept
    }
}
