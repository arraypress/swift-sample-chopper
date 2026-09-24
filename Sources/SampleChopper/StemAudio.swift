//
//  StemAudio.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  A stem in memory at its own sample rate, plus the small signal helpers
//  every cutter needs: mono mixes, envelopes in dBFS, zero-crossing snaps,
//  fades, resampling to a model's rate, and writing a slice to disk.
//

import AVFoundation
import Foundation
import MusicTranscriber

/// One stem's samples.
public struct StemAudio: Sendable {

    public enum Kind: String, CaseIterable, Sendable { case drums, bass, other, vocals }

    public let kind: Kind
    public let url: URL
    public let sampleRate: Double
    /// `[channel][sample]`, one or two channels.
    public let channels: [[Float]]
    /// The mean of the channels.
    public let mono: [Float]

    public var count: Int { channels[0].count }
    public var seconds: Double { Double(count) / sampleRate }

    public init(kind: Kind, url: URL) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ChopperError.audioUnreadable("\(url.lastPathComponent): \(error.localizedDescription)") }
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { throw ChopperError.audioUnreadable("\(url.lastPathComponent) is empty") }
        var channels = [[Float]](repeating: [], count: min(2, channelCount))
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: buffer.frameCapacity) } catch { if channels[0].isEmpty { throw ChopperError.audioUnreadable("\(url.lastPathComponent): \(error.localizedDescription)") }; break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for c in channels.indices { channels[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: frames)) }
        }
        self.kind = kind; self.url = url; self.sampleRate = format.sampleRate; self.channels = channels
        if channels.count == 1 { mono = channels[0] } else {
            var m = [Float](repeating: 0, count: channels[0].count)
            for i in m.indices { m[i] = (channels[0][i] + channels[1][i]) * 0.5 }
            mono = m
        }
    }

    /// A slice of every channel, with fades, as `[channel][sample]`.
    public func slice(_ range: Range<Int>, fadeIn: Double, fadeOut: Double) -> [[Float]] {
        let inSamples = Int(fadeIn * sampleRate), outSamples = Int(fadeOut * sampleRate)
        return channels.map { ch -> [Float] in
            var out = Array(ch[range])
            let n = out.count
            if inSamples > 0 { for i in 0..<min(inSamples, n) { out[i] *= Float(i) / Float(inSamples) } }
            if outSamples > 0 { for i in 0..<min(outSamples, n) { out[n - 1 - i] *= Float(i) / Float(outSamples) } }
            return out
        }
    }

    /// The sample index nearest `time` whose neighbour has the opposite sign (or the index itself).
    public func zeroCrossing(near time: Double, within window: Double = 0.004) -> Int {
        let centre = min(max(0, Int(time * sampleRate)), count - 1)
        let span = Int(window * sampleRate)
        var best = centre, bestDistance = Int.max
        for i in max(1, centre - span)...min(count - 1, centre + span) where (mono[i - 1] <= 0 && mono[i] > 0) || (mono[i - 1] >= 0 && mono[i] < 0) {
            if abs(i - centre) < bestDistance { best = i; bestDistance = abs(i - centre) }
        }
        return best
    }

    /// RMS in dBFS over consecutive windows of `window` seconds.
    public func envelope(window: Double) -> (values: [Float], hop: Int) {
        let hop = max(1, Int(window * sampleRate))
        var out = [Float]()
        out.reserveCapacity(count / hop + 1)
        var i = 0
        while i < count {
            let end = min(count, i + hop)
            var sum: Float = 0
            for k in i..<end { sum += mono[k] * mono[k] }
            out.append(20 * log10(max(1e-9, (sum / Float(end - i)).squareRoot())))
            i += hop
        }
        return (out, hop)
    }

    public static func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var s: Float = 0
        for v in samples { s += v * v }
        return (s / Float(samples.count)).squareRoot()
    }
    public static func dB(_ linear: Float) -> Float { 20 * log10(max(1e-9, linear)) }

    /// Mono at another rate, for a model.
    public func mono(at rate: Double) -> [Float] {
        rate == sampleRate ? mono : Resampler(from: Int(sampleRate), to: Int(rate)).resample(mono)
    }

    public static func write(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AudioWriter.writeWAV(channels: channels, sampleRate: sampleRate, to: url)
    }
}

public enum ChopperError: Error, CustomStringConvertible {
    case audioUnreadable(String), stemsMissing(String), gridFailed(String), modelMissing(String), nothingToCut(String)
    public var description: String {
        switch self {
        case .audioUnreadable(let m): return m
        case .stemsMissing(let m): return m
        case .gridFailed(let m): return m
        case .modelMissing(let m): return m
        case .nothingToCut(let m): return m
        }
    }
}
