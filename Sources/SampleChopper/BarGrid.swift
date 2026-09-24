//
//  BarGrid.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Where the bars are: Beat This! on the drums stem (the beat is clearest
//  there) gives beats and downbeats; the tempo is the median beat gap, a
//  bar is the beats between downbeats, and loops are cut from a detected
//  downbeat for a whole number of tempo-exact bars.
//

import Foundation
import MusicTranscriber

public struct BarGrid: Sendable {

    public let bpm: Double
    public let beatsPerBar: Int
    /// Downbeat times in seconds, as detected.
    public let downbeats: [Double]
    public let beats: [Double]

    public var barSeconds: Double { Double(beatsPerBar) * 60 / bpm }

    /// From Beat This! over a stem (16 kHz mono is what the model reads).
    public static func detect(from stem: StemAudio, tracker: BeatThisTracker) async throws -> BarGrid {
        let (beats, downbeats) = try await tracker.track(samples16k: stem.mono(at: 16_000))
        return try BarGrid(beats: beats, downbeats: downbeats)
    }

    public init(beats: [Double], downbeats: [Double]) throws {
        guard beats.count >= 8, downbeats.count >= 2 else { throw ChopperError.gridFailed("too few beats (\(beats.count)) or downbeats (\(downbeats.count)) to cut bars") }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let median = gaps[gaps.count / 2]
        var bpm = 60 / median
        if abs(bpm - bpm.rounded()) < 0.15 { bpm = bpm.rounded() } else { bpm = (bpm * 10).rounded() / 10 }
        // beats per bar: the typical number of beats between consecutive downbeats
        var counts: [Int: Int] = [:]
        for (a, b) in zip(downbeats, downbeats.dropFirst()) {
            let n = beats.filter { $0 >= a - 1e-3 && $0 < b - 1e-3 }.count
            counts[n, default: 0] += 1
        }
        let beatsPerBar = counts.max { $0.value < $1.value }?.key ?? 4
        self.bpm = bpm; self.beatsPerBar = max(2, min(7, beatsPerBar)); self.downbeats = downbeats; self.beats = beats
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
