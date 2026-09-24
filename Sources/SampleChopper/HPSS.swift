//
//  HPSS.swift
//  SampleChopper
//
//  Created by David Sherlock on 2026.
//
//  Harmonic/percussive separation as librosa does it (Fitzgerald 2010):
//  an STFT of 2048 with hop 512 and a periodic Hann, centred with zero
//  padding; the magnitude median-filtered along time (harmonic, 31 frames)
//  and along frequency (percussive, 31 bins) with reflected edges; soft
//  masks with power 2 (a bin neither layer claims splits evenly); each mask
//  on the complex spectrum; and an inverse STFT normalised by the window's
//  summed squares. The "hits" layer is the percussive one; the "wash" is
//  the harmonic one — sustained cymbals, pads bleeding in, noise sweeps.
//

import Accelerate
import Foundation

public enum HPSS {

    public static let nFFT = 2048
    public static let hop = 512
    public static let kernel = 31
    public static let power: Float = 2

    /// (harmonic, percussive) for mono samples, each the input's length. With `margin` above 1
    /// a bin must beat the other layer's median by that factor to be claimed, and what neither
    /// claims — noise sweeps, washes, tails — is the residual: `x − harmonic − percussive`.
    public static func separate(_ x: [Float], margin: Float = 1) -> (harmonic: [Float], percussive: [Float]) {
        let n = nFFT, bins = n / 2 + 1
        let padded = [Float](repeating: 0, count: n / 2) + x + [Float](repeating: 0, count: n / 2)
        let frames = (padded.count - n) / hop + 1
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(n), .INVERSE) else { return (x, x) }
        defer { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }
        var re = [Float](repeating: 0, count: frames * bins), im = [Float](repeating: 0, count: frames * bins), mag = [Float](repeating: 0, count: frames * bins)
        var inRe = [Float](repeating: 0, count: n), outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        let inIm = [Float](repeating: 0, count: n)
        for f in 0..<frames {
            vDSP_vmul(Array(padded[(f * hop)..<(f * hop + n)]), 1, window, 1, &inRe, 1, vDSP_Length(n))
            vDSP_DFT_Execute(forward, inRe, inIm, &outRe, &outIm)
            for b in 0..<bins { re[f * bins + b] = outRe[b]; im[f * bins + b] = outIm[b]; mag[f * bins + b] = (outRe[b] * outRe[b] + outIm[b] * outIm[b]).squareRoot() }
        }
        // medians: harmonic along time (per bin), percussive along frequency (per frame), reflected edges
        let radius = kernel / 2
        var harm = [Float](repeating: 0, count: frames * bins), perc = [Float](repeating: 0, count: frames * bins)
        var buffer = [Float](repeating: 0, count: kernel)
        func reflect(_ i: Int, _ count: Int) -> Int {          // scipy 'reflect': d c b a | a b c d | d c b a
            var k = i
            while k < 0 || k >= count { if k < 0 { k = -k - 1 }; if k >= count { k = 2 * count - k - 1 } }
            return k
        }
        for b in 0..<bins {
            for f in 0..<frames {
                for j in 0..<kernel { buffer[j] = mag[reflect(f - radius + j, frames) * bins + b] }
                harm[f * bins + b] = median(&buffer)
            }
        }
        for f in 0..<frames {
            for b in 0..<bins {
                for j in 0..<kernel { buffer[j] = mag[f * bins + reflect(b - radius + j, bins)] }
                perc[f * bins + b] = median(&buffer)
            }
        }
        // soft masks (librosa.util.softmask, power 2, split_zeros)
        var hRe = [Float](repeating: 0, count: frames * bins), hIm = hRe, pRe = hRe, pIm = hRe
        let tiny = Float.leastNormalMagnitude
        let splitZeros = margin == 1
        for i in 0..<(frames * bins) {
            // mask_harm = softmask(harm, perc·margin); mask_perc = softmask(perc, harm·margin)
            let zh = max(harm[i], perc[i] * margin), zp = max(perc[i], harm[i] * margin)
            var mh: Float, mp: Float
            if zh < tiny { mh = splitZeros ? 0.5 : 0 } else { let a = pow(harm[i] / zh, power), b = pow(perc[i] * margin / zh, power); mh = a / (a + b) }
            if zp < tiny { mp = splitZeros ? 0.5 : 0 } else { let a = pow(perc[i] / zp, power), b = pow(harm[i] * margin / zp, power); mp = a / (a + b) }
            hRe[i] = re[i] * mh; hIm[i] = im[i] * mh; pRe[i] = re[i] * mp; pIm[i] = im[i] * mp
        }
        func istft(_ sRe: [Float], _ sIm: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: padded.count), norm = [Float](repeating: 0, count: padded.count)
            var fullRe = [Float](repeating: 0, count: n), fullIm = [Float](repeating: 0, count: n)
            var tRe = [Float](repeating: 0, count: n), tIm = [Float](repeating: 0, count: n)
            for f in 0..<frames {
                for b in 0..<bins { fullRe[b] = sRe[f * bins + b]; fullIm[b] = sIm[f * bins + b] }
                for b in 1..<(n / 2) { fullRe[n - b] = fullRe[b]; fullIm[n - b] = -fullIm[b] }     // Hermitian half
                vDSP_DFT_Execute(inverse, fullRe, fullIm, &tRe, &tIm)
                let scale = 1 / Float(n)
                for i in 0..<n { out[f * hop + i] += tRe[i] * scale * window[i]; norm[f * hop + i] += window[i] * window[i] }
            }
            var y = [Float](repeating: 0, count: x.count)
            for i in 0..<x.count { let k = i + n / 2; y[i] = norm[k] > tiny ? out[k] / norm[k] : out[k] }
            return y
        }
        return (istft(hRe, hIm), istft(pRe, pIm))
    }

    /// The noise layer: what neither the tonal nor the transient mask claims at `margin`.
    public static func residual(_ x: [Float], margin: Float = 3) -> [Float] {
        let (h, p) = separate(x, margin: margin)
        var r = x
        for i in r.indices { r[i] -= h[i] + p[i] }
        return r
    }

    static func median(_ v: inout [Float]) -> Float {
        v.sort()
        return v[v.count / 2]
    }
}
