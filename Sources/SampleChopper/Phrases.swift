//
//  Phrases.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Chops from a vocal stem: the stretches where the singer is singing,
//  found from a short RMS envelope, gaps under a quarter second bridged,
//  short blips dropped, a little air kept either side.
//

import Foundation

public struct Phrase: Sendable {
    public let range: Range<Int>
    public let start: Double
    public let seconds: Double
    public let levelDB: Float
}

public enum PhraseCutter {

    public struct Options: Sendable {
        public var window = 0.01
        public var thresholdDB: Float = -42
        public var bridge = 0.25
        public var minimum = 0.3
        public var maximum = 8.0
        public var pad = 0.03
        public var limit = 24
        public init() {}
    }

    public static func cut(_ stem: StemAudio, options: Options = Options()) -> [Phrase] {
        let (env, hop) = stem.envelope(window: options.window)
        let sr = stem.sampleRate
        var regions: [Range<Int>] = []
        var start: Int? = nil
        var lastLoud = 0
        for (i, level) in env.enumerated() {
            if level >= options.thresholdDB {
                if start == nil { start = i }
                lastLoud = i
            } else if let s = start, Double(i - lastLoud) * options.window >= options.bridge {
                regions.append(s..<(lastLoud + 1)); start = nil
            }
        }
        if let s = start { regions.append(s..<(lastLoud + 1)) }
        var phrases: [Phrase] = []
        for r in regions {
            var a = max(0, Int(Double(r.lowerBound * hop) - options.pad * sr)), b = min(stem.count, Int(Double(r.upperBound * hop) + options.pad * sr))
            let seconds = Double(b - a) / sr
            guard seconds >= options.minimum else { continue }
            if seconds > options.maximum { b = a + Int(options.maximum * sr) }
            a = stem.zeroCrossing(near: Double(a) / sr, within: 0.003); b = stem.zeroCrossing(near: Double(b) / sr, within: 0.003)
            phrases.append(Phrase(range: a..<b, start: Double(a) / sr, seconds: Double(b - a) / sr, levelDB: StemAudio.dB(StemAudio.rms(stem.mono[a..<b]))))
        }
        return Array(phrases.sorted { $0.seconds > $1.seconds }.prefix(options.limit).sorted { $0.start < $1.start })
    }
}
