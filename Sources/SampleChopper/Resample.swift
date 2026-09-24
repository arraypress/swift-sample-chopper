//
//  Resample.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//

import Foundation
import MusicTranscriber

enum MusicTranscriberResampler {
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        from == to ? x : Resampler(from: Int(from), to: Int(to)).resample(x)
    }
}
