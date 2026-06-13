//
//  PitchDetector.swift
//  LiveKaraoke — M2
//
//  Monophonic fundamental-frequency (f0) estimation via the YIN algorithm
//  (de Cheveigné & Kawahara, 2002). Used to drive autotune: we detect the
//  singer's pitch, then shift toward the nearest in-key note.
//

import Foundation

final class PitchDetector {
    private let sampleRate: Float
    private let threshold: Float
    private let minF0: Float
    private let maxF0: Float

    // Reused scratch so detection is allocation-free on the audio thread.
    private var diff: [Float]
    private var cmnd: [Float]
    private let tauMax: Int
    private let tauMin: Int

    init(sampleRate: Double,
         minF0: Float = 70,      // ~C#2, low male voice
         maxF0: Float = 1000,    // ~B5, high female voice
         threshold: Float = 0.15) {
        self.sampleRate = Float(sampleRate)
        self.minF0 = minF0
        self.maxF0 = maxF0
        self.threshold = threshold
        self.tauMin = max(2, Int(Float(sampleRate) / maxF0))
        self.tauMax = Int(Float(sampleRate) / minF0)
        self.diff = [Float](repeating: 0, count: tauMax + 1)
        self.cmnd = [Float](repeating: 0, count: tauMax + 1)
    }

    /// Returns detected f0 in Hz, or 0 if the frame is unvoiced/too short.
    func detect(_ x: UnsafeBufferPointer<Float>) -> Float {
        let n = x.count
        guard n >= 2 * tauMax else { return 0 }

        // 1) Difference function d(tau).
        for tau in tauMin...tauMax {
            var sum: Float = 0
            var i = 0
            while i < n - tau {
                let delta = x[i] - x[i + tau]
                sum += delta * delta
                i += 1
            }
            diff[tau] = sum
        }

        // 2) Cumulative mean normalized difference.
        cmnd[0] = 1
        var runningSum: Float = 0
        for tau in tauMin...tauMax {
            runningSum += diff[tau]
            cmnd[tau] = runningSum > 0 ? diff[tau] * Float(tau - tauMin + 1) / runningSum : 1
        }

        // 3) Absolute threshold: first dip below `threshold`.
        var tauEstimate = -1
        var tau = tauMin
        while tau <= tauMax {
            if cmnd[tau] < threshold {
                while tau + 1 <= tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEstimate = tau
                break
            }
            tau += 1
        }
        guard tauEstimate > 0 else { return 0 }   // unvoiced

        // 4) Parabolic interpolation around the dip for sub-sample accuracy.
        let betterTau = parabolicRefine(tauEstimate)
        let f0 = sampleRate / betterTau
        return (f0 >= minF0 && f0 <= maxF0) ? f0 : 0
    }

    private func parabolicRefine(_ tau: Int) -> Float {
        let x0 = tau > tauMin ? tau - 1 : tau
        let x2 = tau < tauMax ? tau + 1 : tau
        if x0 == tau { return Float(tau) }
        if x2 == tau { return Float(tau) }
        let s0 = cmnd[x0], s1 = cmnd[tau], s2 = cmnd[x2]
        let denom = 2 * (2 * s1 - s2 - s0)
        guard denom != 0 else { return Float(tau) }
        return Float(tau) + (s2 - s0) / denom
    }
}
