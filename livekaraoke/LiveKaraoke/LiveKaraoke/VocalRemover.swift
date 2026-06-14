//
//  VocalRemover.swift
//  LiveKaraoke — M1
//
//  Real-time, low-latency vocal removal via mid/side band-split cancellation.
//
//  Idea: lead vocals are usually mixed dead-center, so they live in the MID
//  signal ((L+R)/2). Naively outputting only SIDE ((L-R)/2) cancels the vocal
//  but also guts centered bass and air, and collapses the mix to mono. We do
//  better by keeping the *centered* low and high bands (where bass/kick and
//  cymbals/air live) and only cancelling the center in the vocal band:
//
//     instrumental = LP(mid, fLo)            // centered lows kept
//                  + HP(mid, fHi)            // centered highs/air kept
//                  + bandpass(side, fLo..fHi)// off-center instruments kept
//
//  Centered content between fLo..fHi (the vocals) is dropped. Sub-millisecond,
//  pure biquads. Crude vs. neural separation (that's M4) but instant — which is
//  what the live monitoring loop needs.
//

import Foundation

/// RBJ cookbook biquad, transposed direct form II (a0 normalized to 1).
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    static func lowpass(_ fc: Float, _ fs: Float, q: Float = 0.707) -> Biquad {
        let w0 = 2 * .pi * fc / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: ((1 - cw) / 2) / a0,
                      b1: (1 - cw) / a0,
                      b2: ((1 - cw) / 2) / a0,
                      a1: (-2 * cw) / a0,
                      a2: (1 - alpha) / a0)
    }

    static func highpass(_ fc: Float, _ fs: Float, q: Float = 0.707) -> Biquad {
        let w0 = 2 * .pi * fc / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: ((1 + cw) / 2) / a0,
                      b1: (-(1 + cw)) / a0,
                      b2: ((1 + cw) / 2) / a0,
                      a1: (-2 * cw) / a0,
                      a2: (1 - alpha) / a0)
    }
}

final class VocalRemover {
    /// When false, `process` returns the untouched stereo frame (A/B reference).
    var enabled = true

    // Wider than a "safe" vocal band so we also catch low male fundamentals and
    // sibilance, which are the usual leak paths. The tradeoff (more centered
    // instruments removed → more hollow) is exposed live via `strength`.
    private let fLo: Float = 90       // vocal band lower edge
    private let fHi: Float = 14_000   // vocal band upper edge

    // Makeup gain to offset the energy removed with the centered vocal band.
    var makeupGain: Float = 1.7       // ≈ +4.6 dB

    /// Live "Removal strength" (0…~1.5). How much of the centered vocal band is
    /// subtracted: 1.0 fully cancels a dead-center vocal; >1 over-subtracts to
    /// chase stubborn vocals (at the cost of more hollowness). Audio-thread read.
    var strength: Float = 1.0

    // A band-pass on the MID signal isolates the centered, vocal-range content
    // (lead vocals sit dead-center). We subtract it from each channel, so
    // full-range stereo, bass, and air are all preserved.
    private var midHP: Biquad        // high-pass at fLo
    private var midLP: Biquad        // low-pass at fHi

    init(sampleRate: Double) {
        let fs = Float(sampleRate)
        midHP = .highpass(fLo, fs)
        midLP = .lowpass(fHi, fs)
    }

    func reset() { midHP.reset(); midLP.reset() }

    /// One stereo frame -> one stereo instrumental frame. Keeps the full mix's
    /// width and frequency range; only the centered vocal band is removed.
    @inline(__always)
    func process(left l: Float, right r: Float) -> (Float, Float) {
        if !enabled { return (l, r) }
        let mid = (l + r) * 0.5
        let centerVocal = midLP.process(midHP.process(mid)) * strength
        return ((l - centerVocal) * makeupGain,
                (r - centerVocal) * makeupGain)
    }
}
