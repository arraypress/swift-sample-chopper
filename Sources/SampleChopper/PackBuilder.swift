//
//  PackBuilder.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  A sample pack from a song's stems: the bar grid from the drums, then
//  per stem — drum one-shots named by CLAP, bass one-shots named by CREPE,
//  vocal chops, and tempo-exact loops from every stem — written as WAV at
//  the stems' own rate with a manifest saying where each came from.
//

import Foundation
import MusicAnalysis
import MusicTranscriber
import PitchTracker
import SampleSearch

public struct Pack: Codable, Sendable {

    public struct Item: Codable, Sendable {
        public let file: String
        public let stem: String
        /// one-shot, loop, or chop
        public let kind: String
        public let label: String?
        public let note: String?
        public let cents: Double?
        public let confidence: Double?
        public let bars: Int?
        public let bar: Int
        public let beat: Int
        public let start: Double
        public let seconds: Double
        public let peakDB: Double
        /// For a phrase: how many later spans of the song repeat it.
        public var repeats: Int? = nil

        public init(file: String, stem: String, kind: String, label: String?, note: String?, cents: Double?, confidence: Double?, bars: Int?, bar: Int, beat: Int, start: Double, seconds: Double, peakDB: Double, repeats: Int? = nil) {
            self.file = file; self.stem = stem; self.kind = kind; self.label = label; self.note = note; self.cents = cents; self.confidence = confidence
            self.bars = bars; self.bar = bar; self.beat = beat; self.start = start; self.seconds = seconds; self.peakDB = peakDB; self.repeats = repeats
        }
    }

    public let name: String
    public let bpm: Double
    public let beatsPerBar: Int
    public let bars: Int
    public let key: String?
    public let sampleRate: Double
    public let folder: String
    public var items: [Item]

    public init(name: String, bpm: Double, beatsPerBar: Int, bars: Int, key: String?, sampleRate: Double, folder: String, items: [Item]) {
        self.name = name; self.bpm = bpm; self.beatsPerBar = beatsPerBar; self.bars = bars; self.key = key; self.sampleRate = sampleRate; self.folder = folder; self.items = items
    }

    public func count(kind: String, stem: String? = nil) -> Int { items.filter { $0.kind == kind && (stem == nil || $0.stem == stem) }.count }
}

public struct PackOptions: Sendable {
    public var name: String
    public var oneShotsPerLabel = 8
    public var bassNotesPerName = 2
    public var loops = LoopCutter.Options()
    /// Loop lengths for the melodic stems and for the drums; `bars` overrides both when set.
    public var melodicBars = [4, 2]
    public var drumBars = [4, 2, 1]
    public var bars: [Int]? = nil
    /// Beside each drum loop, a Dry and an FX file: FX is what neither a steady tone nor a
    /// transient claims (median-filter split at margin 3) — sweeps, washes, tails.
    public var drumLayers = false
    /// Drum-pattern MIDI for every drum loop.
    public var drumMidi = true
    /// Whole phrases (4, 8 or 16 bars — the smallest span that repeats) from bass, other, vocals
    /// and a Music stem that sums them, each with its MIDI; the most-repeated are the main parts.
    public var phrases = true
    public var phraseOptions = PhraseFinder.Options()
    /// Force the tempo instead of detecting it; the grid is laid from the first detected downbeat.
    public var fixedTempo: Double? = nil
    public var hits = HitCutter.Options()
    public var onsets = OnsetDetector.Options()
    public var chops = PhraseCutter.Options()
    /// Model locations; nil means each library's installed copy.
    public var beatTracker: URL? = nil
    public var clapFolder: URL? = nil
    public var crepeAsset: URL? = nil
    public var detectKey = true
    /// MIDI for every melodic loop (bass, other, vocals), transcribed from that loop alone with
    /// MuScriptor, bar 1 at the loop's start, the pack's tempo.
    public var midi = true
    /// Also one MIDI file per melodic stem over the whole song (slow: most of a run).
    public var midiFull = false
    public var midiVariant: ModelVariant = .medium
    public var midiModel: URL? = nil
    /// One-shots peak-normalised to this level; nil keeps the stem's own level.
    public var normalizeOneShotsTo: Float? = -1
    /// Hits quieter than this many dB under the stem's loud hits are ghosts and skipped.
    public var quietHitDB: Float = 24
    public init(name: String) { self.name = name }
}

public final class PackBuilder: @unchecked Sendable {

    public let stems: [StemAudio]
    public let options: PackOptions
    public var progress: ((String) -> Void)?

    /// Finds `*-drums.*`, `*-bass.*`, `*-other.*`, `*-vocals.*` in a folder (or takes the files given).
    public static func stems(in folder: URL) throws -> [StemAudio] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [StemAudio] = []
        for kind in StemAudio.Kind.separated {
            guard let url = files.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("-" + kind.rawValue) || $0.deletingPathExtension().lastPathComponent.lowercased() == kind.rawValue }) else { continue }
            found.append(try StemAudio(kind: kind, url: url))
        }
        guard found.contains(where: { $0.kind == .drums }) else {
            throw ChopperError.stemsMissing("no drums stem in \(folder.path): expected files ending in -drums, -bass, -other, -vocals (as stems writes them)")
        }
        return found
    }

    public init(stems: [StemAudio], options: PackOptions) {
        self.stems = stems
        self.options = options
    }

    static let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// Cuts everything and writes it under `folder/<name>/`.
    public func build(into folder: URL) async throws -> Pack {
        let drums = stems.first { $0.kind == .drums }!
        let sr = drums.sampleRate
        let root = folder.appendingPathComponent(options.name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        progress?("bar grid")
        let beatURL = try options.beatTracker ?? ModelLocator.resolveBeatTracker()
        let tracker: BeatThisTracker
        do { tracker = try await BeatThisTracker(contentsOf: beatURL) } catch { throw ChopperError.modelMissing("Beat This! at \(beatURL.path): \(error)") }
        let grid = try await BarGrid.detect(from: drums, tracker: tracker, fixedTempo: options.fixedTempo)

        var key: String? = nil
        if options.detectKey, let harmonic = stems.first(where: { $0.kind == .other }) ?? stems.first(where: { $0.kind == .bass }) {
            progress?("key")
            if let analysis = try? await MusicAnalysis.analyze(url: harmonic.url, only: [.key]), let first = analysis.key.first {
                key = first.tonic + (first.mode.lowercased().hasPrefix("min") ? "min" : "maj")
            }
        }
        let bpmText = grid.bpm == grid.bpm.rounded() ? String(Int(grid.bpm)) : String(format: "%.1f", grid.bpm)
        var items: [Pack.Item] = []
        func item(_ file: URL, stem: StemAudio, kind: String, range: Range<Int>, label: String? = nil, note: String? = nil, cents: Double? = nil, confidence: Double? = nil, bars: Int? = nil, normalised: Bool = false) -> Pack.Item {
            let start = Double(range.lowerBound) / sr
            let pos = grid.position(of: start)
            let peak = normalised ? (options.normalizeOneShotsTo ?? 0) : StemAudio.dB(StemAudio.peak(Array(stem.mono[range])))
            return Pack.Item(file: file.path, stem: stem.kind.rawValue, kind: kind, label: label, note: note, cents: cents.map { ($0 * 10).rounded() / 10 },
                             confidence: confidence.map { ($0 * 1000).rounded() / 1000 }, bars: bars, bar: pos.bar + 1, beat: pos.beat,
                             start: (start * 1000).rounded() / 1000, seconds: (Double(range.count) / sr * 1000).rounded() / 1000, peakDB: (Double(peak) * 10).rounded() / 10)
        }
        func two(_ n: Int) -> String { String(format: "%02d", n) }
        func writeShot(_ stem: StemAudio, _ range: Range<Int>, fadeIn: Double, fadeOut: Double, to file: URL) throws {
            var channels = stem.slice(range, fadeIn: fadeIn, fadeOut: fadeOut)
            if let target = options.normalizeOneShotsTo {
                let peak = channels.map { StemAudio.peak($0) }.max() ?? 0
                if peak > 0 { let gain = pow(10, target / 20) / peak; channels = channels.map { $0.map { $0 * gain } } }
            }
            try StemAudio.write(channels, sampleRate: sr, to: file)
        }
        func loud(_ hits: [Hit]) -> [Hit] {
            guard hits.count > 4 else { return hits }
            let peaks = hits.map(\.peakDB).sorted()
            let reference = peaks[Int(Double(peaks.count - 1) * 0.95)]
            return hits.filter { $0.peakDB >= reference - options.quietHitDB }
        }
        func title(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

        // Drum one-shots
        progress?("drum hits")
        let onsets = OnsetDetector.detect(drums.mono, sampleRate: sr, options: options.onsets)
        let hits = loud(HitCutter.cut(drums, onsets: onsets, options: options.hits))
        let groups = HitCutter.groups(hits)
        progress?("naming \(groups.count) distinct hits of \(hits.count)")
        let clapFolder = options.clapFolder ?? Self.supportRoot.appendingPathComponent("crate")
        let namer: HitNamer
        do { namer = try await HitNamer(embedder: try await ClapEmbedder(inFolder: clapFolder)) } catch { throw ChopperError.modelMissing("CLAP in \(clapFolder.path): \(error)") }
        var byLabel: [String: [(hit: Hit, score: Float, probability: Float)]] = [:]
        for group in groups {
            let lead = group[0]
            let (label, score, probability) = try await namer.name(Array(drums.mono[lead.range]), sampleRate: sr)
            byLabel[label, default: []].append((lead, score, probability))
        }
        var labelled: [(onset: Double, peakDB: Float, label: String)] = []
        for group in groups {
            guard let label = byLabel.first(where: { $0.value.contains { $0.hit.onset == group[0].onset } })?.key else { continue }
            for hit in group { labelled.append((hit.onset, hit.peakDB, label)) }
        }
        for (label, list) in byLabel.sorted(by: { $0.key < $1.key }) {
            let chosen = list.sorted { ($0.hit.cleanliness + 20 * $0.score) > ($1.hit.cleanliness + 20 * $1.score) }.prefix(options.oneShotsPerLabel)
            for (n, entry) in chosen.enumerated() {
                let file = root.appendingPathComponent("Drums/One-shots/\(options.name) - \(title(label)) - \(two(n + 1)).wav")
                try writeShot(drums, entry.hit.range, fadeIn: options.hits.fadeIn, fadeOut: options.hits.fadeOut, to: file)
                items.append(item(file, stem: drums, kind: "one-shot", range: entry.hit.range, label: label, confidence: Double(entry.score), normalised: options.normalizeOneShotsTo != nil))
            }
        }

        // Bass one-shots with note names
        if let bass = stems.first(where: { $0.kind == .bass }) {
            progress?("bass notes")
            let crepeURL = options.crepeAsset ?? Self.supportRoot.appendingPathComponent("tune").appendingPathComponent(CrepeTracker.assetName(.full))
            let noteNamer: NoteNamer
            do { noteNamer = NoteNamer(tracker: try await CrepeTracker(contentsOf: crepeURL)) } catch { throw ChopperError.modelMissing("CREPE at \(crepeURL.path): \(error)") }
            var bassOptions = options.hits; bassOptions.maximum = 2.5; bassOptions.decayDB = -40
            let bassHits = loud(HitCutter.cut(bass, onsets: OnsetDetector.detect(bass.mono, sampleRate: sr, options: options.onsets), options: bassOptions))
            var perNote: [String: Int] = [:]
            for hit in HitCutter.groups(bassHits, threshold: 0.985).map({ $0[0] }).sorted(by: { $0.cleanliness > $1.cleanliness }) where hit.range.count >= Int(0.12 * sr) {
                guard let named = try await noteNamer.name(Array(bass.mono[hit.range]), sampleRate: sr) else { continue }
                let n = perNote[named.note, default: 0] + 1
                guard n <= options.bassNotesPerName else { continue }
                perNote[named.note] = n
                let file = root.appendingPathComponent("Bass/One-shots/\(options.name) - Bass \(named.note) - \(two(n)).wav")
                try writeShot(bass, hit.range, fadeIn: bassOptions.fadeIn, fadeOut: bassOptions.fadeOut, to: file)
                items.append(item(file, stem: bass, kind: "one-shot", range: hit.range, label: "bass", note: named.note, cents: named.cents, confidence: named.confidence, normalised: options.normalizeOneShotsTo != nil))
            }
        }

        // Vocal chops
        if let vocals = stems.first(where: { $0.kind == .vocals }) {
            progress?("vocal chops")
            for (n, phrase) in PhraseCutter.cut(vocals, options: options.chops).enumerated() {
                let file = root.appendingPathComponent("Vocals/Chops/\(options.name) - Vocal Chop - \(two(n + 1)).wav")
                try StemAudio.write(vocals.slice(phrase.range, fadeIn: 0.015, fadeOut: 0.015), sampleRate: sr, to: file)
                items.append(item(file, stem: vocals, kind: "chop", range: phrase.range))
            }
        }

        // Loops from every stem — and, for the melodic stems, MIDI of each loop from that loop alone
        var transcriber: MusicTranscriber? = nil
        if options.midi || options.midiFull {
            let modelURL = try options.midiModel ?? ModelLocator.resolve(variant: options.midiVariant)
            do { transcriber = try await MusicTranscriber(model: modelURL) } catch { throw ChopperError.modelMissing("MuScriptor at \(modelURL.path): \(error)") }
        }
        for stem in stems {
            progress?("\(stem.kind.rawValue) loops")
            var counter: [Int: Int] = [:]
            var loopOptions = options.loops
            loopOptions.lengths = options.bars ?? (stem.kind == .drums ? options.drumBars : options.melodicBars)
            let loops = LoopCutter.cut(stem, grid: grid, options: loopOptions)
            for (i, loop) in loops.enumerated() {
                let n = counter[loop.bars, default: 0] + 1; counter[loop.bars] = n
                let keyPart = key.map { " - \($0)" } ?? ""
                let base = "\(options.name) - \(title(stem.kind.rawValue)) Loop \(loop.bars) Bar - \(bpmText) BPM\(keyPart) - \(two(n))"
                let file = root.appendingPathComponent("\(title(stem.kind.rawValue))/Loops/\(base).wav")
                let slice = stem.slice(loop.range, fadeIn: options.loops.fade, fadeOut: options.loops.fade)
                try StemAudio.write(slice, sampleRate: sr, to: file)
                items.append(item(file, stem: stem, kind: "loop", range: loop.range, bars: loop.bars))
                if stem.kind == .drums {
                    if options.drumLayers {
                        progress?("drum layers \(i + 1)/\(loops.count)")
                        let fx = slice.map { HPSS.residual($0, margin: 3) }
                        let dry = zip(slice, fx).map { zip($0, $1).map { $0 - $1 } }
                        let dryFile = root.appendingPathComponent("Drums/Layers/\(base) (Dry).wav"), fxFile = root.appendingPathComponent("Drums/Layers/\(base) (FX).wav")
                        try StemAudio.write(dry, sampleRate: sr, to: dryFile); try StemAudio.write(fx, sampleRate: sr, to: fxFile)
                        items.append(item(dryFile, stem: stem, kind: "layer", range: loop.range, label: "dry", bars: loop.bars))
                        items.append(item(fxFile, stem: stem, kind: "layer", range: loop.range, label: "fx", bars: loop.bars))
                    }
                    if options.drumMidi {
                        let events = DrumPattern.events(hits: labelled, range: loop.range, sampleRate: sr, bpm: grid.bpm)
                        if !events.isEmpty {
                            let midiFile = root.appendingPathComponent("Drums/MIDI/\(base).mid")
                            try FileManager.default.createDirectory(at: midiFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try DrumPattern.midi(events: events, bpm: grid.bpm, beatsPerBar: grid.beatsPerBar, name: base).write(to: midiFile)
                            items.append(Pack.Item(file: midiFile.path, stem: "drums", kind: "midi", label: nil, note: nil, cents: nil, confidence: nil, bars: loop.bars,
                                                   bar: grid.position(of: loop.start).bar + 1, beat: 1, start: (loop.start * 1000).rounded() / 1000,
                                                   seconds: (Double(loop.range.count) / sr * 1000).rounded() / 1000, peakDB: 0))
                        }
                    }
                }
                if options.midi, stem.kind != .drums, let transcriber {
                    progress?("\(stem.kind.rawValue) loop midi \(i + 1)/\(loops.count)")
                    let transcription = try await transcriber.transcribe(file, tempo: .off)
                    let notes = transcription.notes.filter { !$0.isDrum }.map { n -> TranscribedNote in
                        var m = n; m.onset = max(0, n.onset); m.offset = min(Double(loop.range.count) / sr, max(m.onset + 0.03, n.offset)); return m
                    }
                    guard !notes.isEmpty else { continue }
                    let midiFile = root.appendingPathComponent("\(title(stem.kind.rawValue))/MIDI/\(base).mid")
                    try FileManager.default.createDirectory(at: midiFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try MIDIAssembly.data(notes: notes, grid: BeatGrid.fixed(bpm: grid.bpm, beatsPerBar: grid.beatsPerBar, duration: Double(loop.range.count) / sr)).write(to: midiFile)
                    items.append(Pack.Item(file: midiFile.path, stem: stem.kind.rawValue, kind: "midi", label: nil, note: nil, cents: nil, confidence: nil, bars: loop.bars,
                                           bar: grid.position(of: loop.start).bar + 1, beat: 1, start: (loop.start * 1000).rounded() / 1000,
                                           seconds: (Double(loop.range.count) / sr * 1000).rounded() / 1000, peakDB: 0))
                }
            }
        }

        // Phrases: the smallest repeating span of each melodic stem, and of everything but the drums
        if options.phrases {
            let melodic = stems.filter { $0.kind != .drums }
            var sources = melodic
            if melodic.count >= 2, let music = StemAudio.sum(melodic, kind: .music) { sources.append(music) }
            for stem in sources {
                progress?("\(stem.kind.rawValue) phrases")
                let phrases = PhraseFinder.find(stem, grid: grid, options: options.phraseOptions)
                for (n, phrase) in phrases.enumerated() {
                    let keyPart = key.map { " - \($0)" } ?? ""
                    let base = "\(options.name) - \(title(stem.kind.rawValue)) Phrase \(phrase.bars) Bar - \(bpmText) BPM\(keyPart) - \(two(n + 1))"
                    let file = root.appendingPathComponent("\(title(stem.kind.rawValue))/Phrases/\(base).wav")
                    try StemAudio.write(stem.slice(phrase.range, fadeIn: options.loops.fade, fadeOut: options.loops.fade), sampleRate: sr, to: file)
                    var entry = item(file, stem: stem, kind: "phrase", range: phrase.range, bars: phrase.bars)
                    entry.repeats = phrase.repeats
                    items.append(entry)
                    if options.midi, let transcriber {
                        progress?("\(stem.kind.rawValue) phrase midi \(n + 1)/\(phrases.count)")
                        let transcription = try await transcriber.transcribe(file, tempo: .off)
                        let notes = transcription.notes.filter { !$0.isDrum }.map { note -> TranscribedNote in
                            var m = note; m.onset = max(0, note.onset); m.offset = min(Double(phrase.range.count) / sr, max(m.onset + 0.03, note.offset)); return m
                        }
                        guard !notes.isEmpty else { continue }
                        let midiFile = root.appendingPathComponent("\(title(stem.kind.rawValue))/MIDI/\(base).mid")
                        try FileManager.default.createDirectory(at: midiFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try MIDIAssembly.data(notes: notes, grid: BeatGrid.fixed(bpm: grid.bpm, beatsPerBar: grid.beatsPerBar, duration: Double(phrase.range.count) / sr)).write(to: midiFile)
                        items.append(Pack.Item(file: midiFile.path, stem: stem.kind.rawValue, kind: "midi", label: nil, note: nil, cents: nil, confidence: nil, bars: phrase.bars,
                                               bar: phrase.startBar + 1, beat: 1, start: (phrase.start * 1000).rounded() / 1000,
                                               seconds: (Double(phrase.range.count) / sr * 1000).rounded() / 1000, peakDB: 0, repeats: phrase.repeats))
                    }
                }
            }
        }

        // Whole-stem MIDI (optional), bar 1 on the first downbeat, the pack's tempo
        if options.midiFull, let transcriber {
            let melodic = stems.filter { $0.kind != .drums }
            if !melodic.isEmpty {
                let first = grid.downbeats.first ?? 0
                let fixedGrid = BeatGrid.fixed(bpm: grid.bpm, beatsPerBar: grid.beatsPerBar, duration: drums.seconds)
                for stem in melodic {
                    progress?("\(stem.kind.rawValue) midi (\(options.midiVariant.rawValue))")
                    let transcription = try await transcriber.transcribe(stem.url, tempo: .off)
                    let notes = transcription.notes.filter { !$0.isDrum && $0.onset >= first - 0.02 }.map { n -> TranscribedNote in
                        var m = n; m.onset = max(0, n.onset - first); m.offset = max(m.onset + 0.03, n.offset - first); return m
                    }
                    guard !notes.isEmpty else { continue }
                    let file = root.appendingPathComponent("\(title(stem.kind.rawValue))/MIDI/\(options.name) - \(title(stem.kind.rawValue)) Full - \(bpmText) BPM\(key.map { " - \($0)" } ?? "").mid")
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try MIDIAssembly.data(notes: notes, grid: fixedGrid).write(to: file)
                    items.append(Pack.Item(file: file.path, stem: stem.kind.rawValue, kind: "midi", label: nil, note: nil, cents: nil, confidence: nil, bars: nil,
                                           bar: 1, beat: 1, start: (first * 1000).rounded() / 1000, seconds: (drums.seconds * 10).rounded() / 10, peakDB: 0))
                }
            }
        }

        var pack = Pack(name: options.name, bpm: grid.bpm, beatsPerBar: grid.beatsPerBar, bars: grid.downbeats.count, key: key, sampleRate: sr, folder: root.path, items: [])
        pack.items = items
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pack).write(to: root.appendingPathComponent("manifest.json"))
        return pack
    }
}
