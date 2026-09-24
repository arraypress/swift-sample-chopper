//
//  BarGrid.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Where the bars are: Beat This! on the drums stem (the beat is clearest
//  there) gives beats and downbeats.
//
//  The tempo comes from the DOWNBEATS, not from the beats. Beat This! drops
//  to half-time in sparse sections — on a 140 BPM track its beat list was
//  0.43 s apart under the drums and 0.86 s apart under the breakdowns, so
//  the median beat gap said 71.4 BPM while its own downbeats sat a correct
//  1.72 s apart. So: the bar length is the mean of the consistent downbeat
//  gaps, the beat is the shortest gap the tracker reports consistently, and
//  the time signature is the ratio of the two. Downbeats the tracker missed
//  are filled back in, so a gap of two bars still offers both.
//

import Foundation
import MusicTranscriber

public struct BarGrid: Sendable {

    public let bpm: Double
    public let beatsPerBar: Int
    /// Downbeat times in seconds: those detected, plus any the tracker missed inside a longer gap.
    public let downbeats: [Double]
    public let beats: [Double]

    public var barSeconds: Double { Double(beatsPerBar) * 60 / bpm }

    /// From Beat This! over a stem (16 kHz mono is what the model reads).
    public static func detect(from stem: StemAudio, tracker: BeatThisTracker, fixedTempo: Double? = nil) async throws -> BarGrid {
        let (beats, downbeats) = try await tracker.track(samples16k: stem.mono(at: 16_000))
        return try BarGrid(beats: beats, downbeats: downbeats, fixedTempo: fixedTempo)
    }

    /// `fixedTempo` overrides the detected tempo; the first downbeat is kept and the grid
    /// rebuilt at that tempo, so a half-time or double-time reading can be corrected by hand.
    public init(beats: [Double], downbeats: [Double], fixedTempo: Double? = nil) throws {
        guard beats.count >= 8, downbeats.count >= 3 else {
            throw ChopperError.gridFailed("too few beats (\(beats.count)) or downbeats (\(downbeats.count)) to cut bars")
        }
        let beatGaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let downbeatGaps = zip(downbeats.dropFirst(), downbeats).map { $0 - $1 }.sorted()
        // The bar: the mean of the gaps within 20% of their median, so a missed downbeat
        // (a gap of two or three bars) does not move it.
        let barMedian = downbeatGaps[downbeatGaps.count / 2]
        let consistentBars = downbeatGaps.filter { abs($0 - barMedian) <= 0.2 * barMedian }
        let bar = consistentBars.isEmpty ? barMedian : consistentBars.reduce(0, +) / Double(consistentBars.count)
        // The beat: the same treatment around the SMALLEST cluster of beat gaps, because the
        // tracker's misses are always longer than the truth, never shorter.
        let beatFloor = beatGaps[max(0, beatGaps.count / 10)]
        let consistentBeats = beatGaps.filter { abs($0 - beatFloor) <= 0.2 * beatFloor }
        let beat = consistentBeats.isEmpty ? beatFloor : consistentBeats.reduce(0, +) / Double(consistentBeats.count)
        var beatsPerBar = beat > 0 ? Int((bar / beat).rounded()) : 4
        if !(2...8).contains(beatsPerBar) { beatsPerBar = 4 }
        var bpm = Double(beatsPerBar) * 60 / bar
        if let fixedTempo { bpm = fixedTempo } else if abs(bpm - bpm.rounded()) < 0.15 { bpm = bpm.rounded() } else { bpm = (bpm * 10).rounded() / 10 }
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.beats = beats
        // Fill the downbeats the tracker missed: a gap close to a whole number of bars gets its
        // inner downbeats back. With a fixed tempo the grid is laid from the first downbeat.
        let barLength = Double(beatsPerBar) * 60 / bpm
        if fixedTempo != nil, let first = downbeats.first, let last = downbeats.last, barLength > 0 {
            self.downbeats = stride(from: first, through: last, by: barLength).map { $0 }
        } else {
            var filled: [Double] = []
            for (i, d) in downbeats.enumerated() {
                filled.append(d)
                guard i + 1 < downbeats.count else { continue }
                let gap = downbeats[i + 1] - d
                let bars = (gap / barLength).rounded()
                guard bars >= 2, abs(gap - bars * barLength) <= 0.1 * barLength else { continue }
                for k in 1..<Int(bars) { filled.append(d + Double(k) * gap / bars) }
            }
            self.downbeats = filled
        }
    }

    /// The bar index (0-based) and the beat within it (1-based) at `time`.
    public func position(of time: Double) -> (bar: Int, beat: Int) {
        var bar = 0
        for (i, d) in downbeats.enumerated() where d <= time + 1e-6 { bar = i }
        let start = downbeats[min(bar, downbeats.count - 1)]
        let beat = Int(((time - start) / (60 / bpm)).rounded(.down)) + 1
        return (bar, max(1, min(beatsPerBar, beat)))
    }
}
