//
//  Loops.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Loops from any stem: whole bars from a detected downbeat, a tempo-exact
//  number of bars long, where the stem is actually playing; near-repeats
//  of the same bar pattern counted once, the fullest kept.
//

import Foundation

public struct Loop: Sendable {
    public let bars: Int
    public let startBar: Int
    public let range: Range<Int>
    public let start: Double
    public let levelDB: Float
    /// RMS per sixteenth, normalised, for de-duplication.
    public let pattern: [Float]
}

public enum LoopCutter {

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    public struct Options: Sendable {
        public var lengths = [4, 2, 1]
        /// A bar counts as playing when its RMS is at least this fraction (in dB) under the stem's loud bars.
        public var activeBelowLoudDB: Float = 9
        public var similarity: Float = 0.92
        public var perLength = 4
        public var fade = 0.002
        public init() {}
    }

    public static func cut(_ stem: StemAudio, grid: BarGrid, options: Options = Options()) -> [Loop] {
        let sr = stem.sampleRate
        let barSamples = Int((grid.barSeconds * sr).rounded())
        let sixteenth = max(1, barSamples / (grid.beatsPerBar * 4))
        // bar levels
        var bars: [(start: Int, level: Float)] = []
        for d in grid.downbeats {
            let start = Int((d * sr).rounded())
            guard start + barSamples <= stem.count else { break }
            bars.append((start, StemAudio.dB(StemAudio.rms(stem.mono[start..<(start + barSamples)]))))
        }
        guard bars.count >= 2 else { return [] }
        let loud = bars.map(\.level).sorted()[Int(Double(bars.count - 1) * 0.9)]
        let active = bars.map { $0.level >= loud - options.activeBelowLoudDB && $0.level > -50 }
        var loops: [Loop] = []
        for length in options.lengths {
            var kept: [Loop] = []
            var candidates: [Loop] = []
            var i = 0
            while i + length <= bars.count {
                if (i..<(i + length)).allSatisfy({ active[$0] }) {
                    let start = bars[i].start, end = start + Int((Double(length) * grid.barSeconds * sr).rounded())   // tempo-exact, rounded once
                    guard end <= stem.count else { i += 1; continue }
                    var pattern = [Float]()
                    var k = start
                    while k + sixteenth <= end { pattern.append(StemAudio.rms(stem.mono[k..<(k + sixteenth)])); k += sixteenth }
                    let norm = pattern.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    let level = bars[i..<(i + length)].map(\.level).reduce(0, +) / Float(length)
                    let unit: [Float] = norm > 0 ? pattern.map { $0 / norm } : pattern
                    candidates.append(Loop(bars: length, startBar: i, range: start..<end, start: Double(start) / sr, levelDB: level, pattern: unit))
                }
                i += 1
            }
            for c in candidates.sorted(by: { $0.levelDB > $1.levelDB }) {
                if kept.contains(where: { dot($0.pattern, c.pattern) >= options.similarity }) { continue }
                kept.append(c)
                if kept.count >= options.perLength { break }
            }
            loops.append(contentsOf: kept.sorted { $0.startBar < $1.startBar })
        }
        return loops
    }
}

