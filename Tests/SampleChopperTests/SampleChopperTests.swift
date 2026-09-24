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
