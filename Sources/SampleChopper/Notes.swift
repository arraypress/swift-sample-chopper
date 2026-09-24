//
//  Notes.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Note names for tonal one-shots: CREPE over the hit, the median of its
//  confident frames, the nearest note and the cents off.
//

import Foundation
import PitchTracker

public struct NoteNamer: Sendable {

    let tracker: CrepeTracker

    public init(tracker: CrepeTracker) { self.tracker = tracker }

    /// "C2" and the cents off, or nil when fewer than a third of the frames are confident.
    public func name(_ samples: [Float], sampleRate: Double, threshold: Double = 0.7) async throws -> (note: String, cents: Double, confidence: Double)? {
        let s16 = MusicTranscriberResampler.resample(samples, from: sampleRate, to: 16_000)
        let track = try await tracker.track(samples16k: s16)
        let voiced = track.frames.filter { $0.confidence >= threshold }
        guard voiced.count >= max(3, track.frames.count / 3) else { return nil }
        let midis = voiced.map(\.midi).sorted()
        let median = midis[midis.count / 2]
        let (note, cents) = PitchTrack.nearest(midi: median)
        return (PitchTrack.name(midi: note), cents, voiced.map(\.confidence).sorted()[voiced.count / 2])
    }
}
