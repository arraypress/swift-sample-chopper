//
//  SampleChopperTests.swift
//  SampleChopperTests
//
//  Created by David Sherlock on 2026.
//
//  The cutters on synthetic signals with known answers, and — with
//  CHOP_STEMS pointing at a folder of stems and the three models installed —
//  a whole pack built and counted.
//

import Foundation
import MIDIFileKit
import MusicTranscriber
import Testing
@testable import SampleChopper

private func click(at times: [Double], seconds: Double, rate: Double = 48_000) -> [Float] {
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    for t in times {
        let s = Int(t * rate)
        for i in 0..<Int(0.03 * rate) where s + i < x.count { x[s + i] += Float(sin(Double(i) * 0.9) * exp(-Double(i) / (0.004 * rate))) * 0.8 }
    }
    return x
}

@Suite struct CutterTests {

    @Test("onsets land on synthetic clicks within a frame")
    func onsets() {
        let times: [Double] = [0.5, 1.0, 1.25, 2.0, 2.75, 3.0]
        let found = OnsetDetector.detect(click(at: times, seconds: 4), sampleRate: 48_000)
        #expect(found.count == times.count, "\(found)")
        for (a, b) in zip(times, found) { #expect(abs(a - b) < 0.012, "\(a) vs \(b)") }
    }

    @Test("the grid reads tempo and beats per bar from beat times")
    func grid() throws {
        let bpm = 128.0
        let beats = (0..<64).map { Double($0) * 60 / bpm + 0.1 }
        let downbeats = stride(from: 0, to: 64, by: 4).map { beats[$0] }
        let g = try BarGrid(beats: beats, downbeats: downbeats)
        #expect(g.bpm == 128 && g.beatsPerBar == 4 && abs(g.barSeconds - 1.875) < 1e-9)
        #expect(g.position(of: 0.1 + 1.875 * 2 + 0.47).bar == 2 && g.position(of: 0.1 + 1.875 * 2 + 0.47).beat == 2)
    }

    /// Beat This! halves its beat rate under sparse sections and misses the odd downbeat;
    /// the tempo must still come out at the downbeats' rate, and the missed bars come back.
    @Test("half-time beats and missed downbeats do not move the tempo")
    func halfTimeBeats() throws {
        let bpm = 140.0, beat = 60 / bpm, bar = 4 * beat
        var beats: [Double] = [], downbeats: [Double] = []
        for i in 0..<40 {
            let start = 0.92 + Double(i) * bar
            downbeats.append(start)
            // the first half of the track at the true rate, the second at half-time
            for k in 0..<4 where i < 20 || k % 2 == 0 { beats.append(start + Double(k) * beat) }
        }
        let missing = Set([7, 13, 26])                 // three downbeats the tracker did not report
        let g = try BarGrid(beats: beats, downbeats: downbeats.enumerated().filter { !missing.contains($0.offset) }.map(\.element))
        #expect(abs(g.bpm - 140) < 0.2, Comment(rawValue: "\(g.bpm)"))
        #expect(g.beatsPerBar == 4)
        #expect(g.downbeats.count == 40, Comment(rawValue: "\(g.downbeats.count) downbeats, expected the three missing ones filled in"))
        // a forced tempo lays a clean grid from the first downbeat
        let forced = try BarGrid(beats: beats, downbeats: downbeats, fixedTempo: 70)
        #expect(forced.bpm == 70 && abs(forced.barSeconds - 2 * bar) < 1e-9 && forced.downbeats.count == 20)
    }

    @Test("phrases bridge short gaps and drop blips")
    func phrases() throws {
        var x = [Float](repeating: 0, count: 48_000 * 4)
        for i in 24_000..<48_000 { x[i] = 0.3 }                 // 0.5–1.0 s
        for i in 52_800..<72_000 { x[i] = 0.3 }                 // 1.1–1.5 s: a 100 ms gap, bridged
        for i in 120_000..<121_000 { x[i] = 0.3 }               // a 20 ms blip, dropped
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chop-\(UUID().uuidString).wav")
        try StemAudio.write([x], sampleRate: 48_000, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let stem = try StemAudio(kind: .vocals, url: url)
        let phrases = PhraseCutter.cut(stem)
        #expect(phrases.count == 1 && abs(phrases[0].start - 0.47) < 0.02 && abs(phrases[0].seconds - 1.06) < 0.03, "\(phrases.map { ($0.start, $0.seconds) })")
    }
}

@Suite struct PhraseTests {

    /// A synthesised chord sequence: bars A B C D repeated, then E F repeated — phrases of 4 and 2 bars.
    @Test("phrase length is the smallest span that repeats")
    func phrases() throws {
        let sr = 48_000.0, bpm = 120.0, bar = 2.0
        let chords: [[Double]] = [[261.6, 329.6, 392.0], [293.7, 349.2, 440.0], [329.6, 392.0, 493.9], [349.2, 440.0, 523.3],   // A B C D
                                  [220.0, 261.6, 329.6], [196.0, 246.9, 293.7]]                                                // E F
        let sequence = [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 4, 5, 4, 5, 4, 5]
        var x = [Float](repeating: 0, count: Int(Double(sequence.count) * bar * sr))
        for (b, c) in sequence.enumerated() {
            for i in 0..<Int(bar * sr) { let t = Double(i) / sr; x[b * Int(bar * sr) + i] = Float(chords[c].map { sin(2 * .pi * $0 * t) }.reduce(0, +) * 0.2) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phrase-\(UUID().uuidString).wav")
        try StemAudio.write([x], sampleRate: sr, to: url); defer { try? FileManager.default.removeItem(at: url) }
        let stem = try StemAudio(kind: .other, url: url)
        let beats = (0..<(sequence.count * 4)).map { Double($0) * 60 / bpm }
        let grid = try BarGrid(beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] })
        let (bars, _) = PhraseFinder.barDescriptors(stem, grid: grid)
        print("bar similarities vs bar 0: " + (1..<6).map { String(format: "%.2f", PhraseFinder.similarity(bars[0], bars[$0])) }.joined(separator: " ") + " | 12 vs 13, 14: " + [13, 14].map { String(format: "%.2f", PhraseFinder.similarity(bars[12], bars[$0])) }.joined(separator: " "))
        var options = PhraseFinder.Options(); options.lengths = [2, 4, 8]
        let phrases = PhraseFinder.find(stem, grid: grid, options: options)
        let byStart = phrases.sorted { $0.startBar < $1.startBar }
        #expect(byStart.map { ($0.startBar, $0.bars) }.map { "\($0)" } == ["(0, 4)", "(12, 2)"], "\(byStart.map { ($0.startBar, $0.bars, $0.repeats) })")
        #expect(byStart[0].repeats == 2 && byStart[1].repeats == 3)
    }
}

@Suite struct DrumPatternTests {

    @Test("hits inside the loop become General MIDI notes at their beats with velocity from level")
    func events() throws {
        let sr = 48_000.0, bpm = 120.0
        let hits: [(onset: Double, peakDB: Float, label: String)] = [
            (1.0, -1, "kick"), (1.5, -13, "hat"), (2.0, -4, "snare"), (2.5, -40, "hat"), (2.9, -2, "fx"), (3.1, -1, "kick"),
        ]
        let range = Int(1.0 * sr)..<Int(3.0 * sr)           // 2 s = one bar at 120
        let events = DrumPattern.events(hits: hits, range: range, sampleRate: sr, bpm: bpm)
        #expect(events.map(\.note) == [36, 42, 38, 42], "fx is skipped, the kick at 3.1 is outside")
        #expect(events.map { ($0.beat * 100).rounded() / 100 } == [0, 1, 2, 3])
        #expect(events[0].velocity == 127 && events[1].velocity == Int((127 - 12.0 / 24 * 87).rounded()) && events[3].velocity == 40)
        let data = try DrumPattern.midi(events: events, bpm: bpm, beatsPerBar: 4, name: "test")
        let file = try MIDIReader.read(data)
        #expect(file.notes.map(\.pitch.number) == [36, 42, 38, 42] && file.notes.allSatisfy { $0.channel == 9 })
        #expect(abs(file.tempoMap.initial.bpm - 120) < 0.01)
    }
}

@Suite struct HPSSTests {

    private func floats(_ name: String) throws -> [Float] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "f32", subdirectory: "Fixtures"))
        return try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    private func psnr(_ a: [Float], _ b: [Float]) -> Double {
        var err = 0.0, lo = Double.infinity, hi = -Double.infinity
        for i in a.indices { let d = Double(a[i]) - Double(b[i]); err += d * d; lo = min(lo, Double(a[i])); hi = max(hi, Double(a[i])) }
        let mse = err / Double(a.count); return mse == 0 ? .infinity : 20 * log10((hi - lo) / mse.squareRoot())
    }

    @Test("the split matches librosa.effects.hpss at margins 1 and 3", arguments: [Float(1), Float(3)])
    func parity(margin: Float) throws {
        let x = try floats("hpss_input")
        let tag = margin == 1 ? "" : "_m\(Int(margin))"
        let refH = try floats("hpss_harmonic\(tag)"), refP = try floats("hpss_percussive\(tag)")
        let (h, p) = HPSS.separate(x, margin: margin)
        #expect(h.count == refH.count && p.count == refP.count)
        let dbH = psnr(refH, h), dbP = psnr(refP, p)
        print("hpss margin \(margin): harmonic \(String(format: "%.1f", dbH)) dB, percussive \(String(format: "%.1f", dbP)) dB")
        #expect(dbH > 60 && dbP > 60)
    }
}

@Suite struct GridDiagnostics {
    @Test("what Beat This! returns for a stem", .enabled(if: ProcessInfo.processInfo.environment["CHOP_STEMS"] != nil))
    func grid() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHOP_STEMS"]!)
        let drums = try PackBuilder.stems(in: folder).first { $0.kind == .drums }!
        let tracker = try await BeatThisTracker(contentsOf: ModelLocator.resolveBeatTracker())
        let (beats, downbeats) = try await tracker.track(samples16k: drums.mono(at: 16_000))
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let dgaps = zip(downbeats.dropFirst(), downbeats).map { $0 - $1 }.sorted()
        print("stem \(String(format: "%.1f", drums.seconds))s | beats \(beats.count) | downbeats \(downbeats.count)")
        print("  beat gap: median \(String(format: "%.3f", gaps[gaps.count/2]))s → \(String(format: "%.1f", 60/gaps[gaps.count/2])) BPM; 10th \(String(format: "%.3f", gaps[gaps.count/10]))s, 90th \(String(format: "%.3f", gaps[gaps.count*9/10]))s")
        print("  downbeat gap: median \(String(format: "%.3f", dgaps[dgaps.count/2]))s; 10th \(String(format: "%.3f", dgaps[dgaps.count/10]))s, 90th \(String(format: "%.3f", dgaps[dgaps.count*9/10]))s")
        print("  beats per bar counts: \(Dictionary(grouping: zip(downbeats, downbeats.dropFirst()).map { a, b in beats.filter { $0 >= a - 1e-3 && $0 < b - 1e-3 }.count }, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key })")
        print("  first beats: \(beats.prefix(9).map { String(format: "%.3f", $0) })")
        print("  first downbeats: \(downbeats.prefix(5).map { String(format: "%.3f", $0) })")
        let g = try BarGrid(beats: beats, downbeats: downbeats)
        print("  BarGrid → \(g.bpm) BPM, \(g.beatsPerBar)/4, bar \(String(format: "%.3f", g.barSeconds))s, \(g.downbeats.count) downbeats")
    }
}

@Suite struct PhraseDiagnostics {
    @Test("repeat scores on real stems", .enabled(if: ProcessInfo.processInfo.environment["CHOP_STEMS"] != nil))
    func scores() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHOP_STEMS"]!)
        let stems = try PackBuilder.stems(in: folder)
        let drums = stems.first { $0.kind == .drums }!
        let tracker = try await BeatThisTracker(contentsOf: ModelLocator.resolveBeatTracker())
        let grid = try await BarGrid.detect(from: drums, tracker: tracker)
        var sources = stems.filter { $0.kind != .drums }
        if let music = StemAudio.sum(sources, kind: .music) { sources.append(music) }
        for stem in sources {
            let sc = PhraseFinder.scores(stem, grid: grid)
            print("\(stem.kind.rawValue): bar  r4   r8   r16")
            for s in stride(from: 16, to: min(sc.count, 72), by: 4) {
                let d = sc[s]
                print(String(format: "  %3d  %@", s, [4, 8, 16].map { d[$0].map { String(format: "%.2f", $0) } ?? " -- " }.joined(separator: " ")))
            }
        }
    }
}

@Suite struct PackTests {

    @Test("a whole pack from real stems", .enabled(if: ProcessInfo.processInfo.environment["CHOP_STEMS"] != nil))
    func realPack() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHOP_STEMS"]!)
        let stems = try PackBuilder.stems(in: folder)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHOP_OUT"] ?? NSTemporaryDirectory())
        let builder = PackBuilder(stems: stems, options: PackOptions(name: "Test Pack"))
        builder.progress = { print("  …\($0)") }
        let started = Date()
        let pack = try await builder.build(into: out)
        print("pack: \(pack.bpm) bpm, \(pack.beatsPerBar)/4, \(pack.bars) bars, key \(pack.key ?? "-"), \(pack.items.count) files in \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
        for stem in StemAudio.Kind.allCases {
            print("  \(stem): one-shots \(pack.count(kind: "one-shot", stem: stem.rawValue)), loops \(pack.count(kind: "loop", stem: stem.rawValue)), chops \(pack.count(kind: "chop", stem: stem.rawValue))")
        }
        let labels = Dictionary(grouping: pack.items.filter { $0.kind == "one-shot" && $0.stem == "drums" }, by: { $0.label ?? "?" }).mapValues(\.count)
        print("  drum labels: \(labels.sorted { $0.key < $1.key })")
        print("  bass notes: \(pack.items.filter { $0.note != nil }.map { "\($0.note!) \($0.cents!)" })")
        #expect(pack.items.count > 20)
    }
}
