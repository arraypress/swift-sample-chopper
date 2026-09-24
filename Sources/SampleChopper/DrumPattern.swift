//
//  DrumPattern.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  A drum loop as MIDI: every hit inside the loop at its beat, on the
//  General MIDI drum note its label maps to, velocity from its peak.
//

import Foundation
import MIDIFileKit

public enum DrumPattern {

    /// General MIDI percussion notes for the labels `HitNamer` gives.
    public static let generalMIDI: [String: Int] = [
        "kick": 36, "snare": 38, "clap": 39, "hat": 42, "open-hat": 46, "tom": 45, "crash": 49, "ride": 51, "perc": 37,
    ]

    public struct Event: Sendable {
        public let beat: Double
        public let note: Int
        public let velocity: Int
        public let label: String
    }

    /// Hits with a known label inside `range`, as beats from the loop's start; velocity 40…127
    /// from the hit's peak against the loudest hit in the loop.
    public static func events(hits: [(onset: Double, peakDB: Float, label: String)], range: Range<Int>, sampleRate: Double, bpm: Double) -> [Event] {
        let start = Double(range.lowerBound) / sampleRate, end = Double(range.upperBound) / sampleRate
        let inside = hits.filter { $0.onset >= start - 0.002 && $0.onset < end - 0.002 && generalMIDI[$0.label] != nil }
        guard let loudest = inside.map(\.peakDB).max() else { return [] }
        return inside.map { hit in
            let relative = max(-24, min(0, hit.peakDB - loudest))          // −24…0 dB → 40…127
            let velocity = Int((127 + Double(relative) / 24 * 87).rounded())
            return Event(beat: max(0, hit.onset - start) * bpm / 60, note: generalMIDI[hit.label]!, velocity: max(1, min(127, velocity)), label: hit.label)
        }
    }

    /// A one-track MIDI file on channel 10 (drums), one sixteenth per hit, at `bpm`.
    public static func midi(events: [Event], bpm: Double, beatsPerBar: Int, name: String) throws -> Data {
        var composition = Composition(bpm: bpm, timeSignature: (beatsPerBar, 4), ticksPerQuarterNote: 480)
        composition.addTrack(name: name, channel: 9, program: nil) { track in
            for e in events { track.note(e.note, atBeat: e.beat, lasting: 0.25, velocity: e.velocity) }
        }
        return try MIDIWriter.data(for: composition.build())
    }
}
