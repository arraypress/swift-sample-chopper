//
//  BarGrid.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Where the bars are. Beat This! on the drums stem gives beats and
//  downbeats, but both need reading with care:
//
//  * It drops to half-time under sparse sections, so the median beat gap
//    said 71.4 BPM on a 140 BPM track. The beat is the mean of the SHORTEST
//    consistent cluster of gaps, because its mistakes are always too long.
//  * It sometimes marks a downbeat every half bar — on one 4/4 track its
//    downbeats sat two beats apart, which read as 2/4 and made every
//    "4 bar" loop two bars long. So the time signature is not taken from
//    that spacing: three beats to the bar when the ratio says three, four
//    otherwise, which is what dance music is.
//
//  The tempo and the phase are then settled against the audio itself: a
//  click train is slid and stretched over the drums' onset envelope, and
//  the period and offset that collect the most onset energy win. That is
//  what tells 135.8 BPM from 136 (the first scores four times the second
//  on a track whose upload runs slightly slow), and which of the candidate
//  bar starts is beat one.
//

import Foundation
import MusicTranscriber

public struct BarGrid: Sendable {

    public let bpm: Double
    public let beatsPerBar: Int
    /// A uniform grid of bar starts across the track.
    public var downbeats: [Double] { downbeats_ }
    public let beats: [Double]
    /// True when the tempo and phase were fitted to the audio rather than read off the tracker.
    public let refined: Bool

    public var barSeconds: Double { Double(beatsPerBar) * 60 / bpm }

    /// An onset envelope to fit against: values, the hop between them in samples, and the rate.
    public struct Envelope: Sendable {
        public let values: [Float]
        /// The same envelope below 200 Hz, for finding beat one — in dance music that is the kick.
        public let bass: [Float]
        public let hop: Int
        public let sampleRate: Double
        public init(values: [Float], bass: [Float] = [], hop: Int, sampleRate: Double) {
            self.values = values; self.bass = bass; self.hop = hop; self.sampleRate = sampleRate
        }
        func strength(at time: Double, bassOnly: Bool) -> Float {
            let v = bassOnly && !bass.isEmpty ? bass : values
            let i = Int((time * sampleRate / Double(hop)).rounded())
            return i >= 0 && i < v.count ? v[i] : 0
        }
        /// Mean strength of a click train of `period` seconds from `start` until the envelope ends.
        func score(start: Double, period: Double, bassOnly: Bool = false) -> Float {
            guard period > 0 else { return 0 }
            let end = Double(values.count * hop) / sampleRate
            var total: Float = 0, n = 0
            var t = start
            while t < end { total += strength(at: t, bassOnly: bassOnly); n += 1; t += period }
            return n > 0 ? total / Float(n) : 0
        }
    }

    /// From Beat This! over a stem (16 kHz mono is what the model reads), fitted to that stem's onsets.
    public static func detect(from stem: StemAudio, tracker: BeatThisTracker, fixedTempo: Double? = nil) async throws -> BarGrid {
        let (beats, downbeats) = try await tracker.track(samples16k: stem.mono(at: 16_000))
        let (values, hop) = OnsetDetector.envelope(stem.mono, sampleRate: stem.sampleRate)
        let (bass, _) = OnsetDetector.envelope(stem.mono, sampleRate: stem.sampleRate, below: 200)
        let envelope = values.isEmpty ? nil : Envelope(values: values, bass: bass, hop: hop, sampleRate: stem.sampleRate)
        return try BarGrid(beats: beats, downbeats: downbeats, fixedTempo: fixedTempo, envelope: envelope)
    }

    /// `fixedTempo` overrides the fitted tempo; the phase is still fitted, so the bars land on the music.
    public init(beats: [Double], downbeats: [Double], fixedTempo: Double? = nil, envelope: Envelope? = nil) throws {
        guard beats.count >= 8, downbeats.count >= 3 else {
            throw ChopperError.gridFailed("too few beats (\(beats.count)) or downbeats (\(downbeats.count)) to cut bars")
        }
        // The beat: the mean of the shortest consistent cluster of gaps.
        let beatGaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let floor = beatGaps[max(0, beatGaps.count / 10)]
        let nearFloor = beatGaps.filter { abs($0 - floor) <= 0.2 * floor }
        var beat = nearFloor.isEmpty ? floor : nearFloor.reduce(0, +) / Double(nearFloor.count)
        // The tracker's own downbeat spacing, only to tell three-four from four-four.
        let downbeatGaps = zip(downbeats.dropFirst(), downbeats).map { $0 - $1 }.sorted()
        let barMedian = downbeatGaps[downbeatGaps.count / 2]
        let consistent = downbeatGaps.filter { abs($0 - barMedian) <= 0.2 * barMedian }
        let rawBar = consistent.isEmpty ? barMedian : consistent.reduce(0, +) / Double(consistent.count)
        let ratio = beat > 0 ? Int((rawBar / beat).rounded()) : 4
        beatsPerBar = (ratio == 3 || ratio == 6) ? 3 : 4
        // Fit the beat period and its phase to the audio.
        var phase = downbeats[0].truncatingRemainder(dividingBy: max(beat, 1e-6))
        var fitted = false
        if let envelope, fixedTempo == nil {
            var best: (score: Float, period: Double, phase: Double) = (-1, beat, phase)
            for step in -60...60 {
                let period = beat * (1 + Double(step) * 0.0005)      // ±3%, in 0.05% steps
                guard period > 0 else { continue }
                for p in 0..<48 {
                    let offset = Double(p) / 48 * period
                    let score = envelope.score(start: offset, period: period)
                    if score > best.score { best = (score, period, offset) }
                }
            }
            beat = best.period; phase = best.phase; fitted = true
        } else if let envelope {
            let period = 60 / fixedTempo!
            var best: (score: Float, phase: Double) = (-1, 0)
            for p in 0..<96 {
                let offset = Double(p) / 96 * period
                let score = envelope.score(start: offset, period: period)
                if score > best.score { best = (score, offset) }
            }
            beat = period; phase = best.phase; fitted = true
        }
        refined = fitted
        var tempo = fixedTempo ?? 60 / beat
        if fixedTempo == nil { tempo = abs(tempo - tempo.rounded()) < 0.05 ? tempo.rounded() : (tempo * 10).rounded() / 10 }
        bpm = tempo
        self.beats = beats
        // Which beat is beat one: the candidate bar start that collects the most onset energy,
        // falling back to the tracker's first downbeat.
        let barLength = Double(beatsPerBar) * 60 / tempo
        var barPhase = phase
        if let envelope, fitted {
            var best: (score: Float, phase: Double) = (-1, phase)
            for j in 0..<beatsPerBar {
                let candidate = phase + Double(j) * beat
                let score = envelope.score(start: candidate, period: barLength, bassOnly: true)
                if score > best.score { best = (score, candidate) }
            }
            barPhase = best.phase
        } else {
            barPhase = downbeats[0].truncatingRemainder(dividingBy: barLength)
        }
        let last = max(beats.last ?? 0, downbeats.last ?? 0)
        var grid: [Double] = []
        var t = barPhase
        while t < 0 { t += barLength }
        while t <= last { grid.append(t); t += barLength }
        self.downbeats_ = grid
    }

    // Stored through a private name so the fitted grid can be assigned after `bpm`.
    private let downbeats_: [Double]

    /// The bar index (0-based) and the beat within it (1-based) at `time`.
    public func position(of time: Double) -> (bar: Int, beat: Int) {
        guard let first = downbeats.first, barSeconds > 0 else { return (0, 1) }
        let offset = time - first
        let bar = Int((offset / barSeconds).rounded(.down))
        let within = offset - Double(bar) * barSeconds
        let beat = Int((within / (60 / bpm)).rounded(.down)) + 1
        return (max(0, bar), max(1, min(beatsPerBar, beat)))
    }
}
