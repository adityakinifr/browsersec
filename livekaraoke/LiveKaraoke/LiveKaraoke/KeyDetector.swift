//
//  KeyDetector.swift
//  LiveKaraoke — M5
//
//  Estimates the musical key of the backing track so autotune can snap to the
//  right scale automatically. We accumulate a chroma (pitch-class energy) vector
//  via FFT, then correlate it against Krumhansl–Schmuckler key profiles to pick
//  the best major/minor key.
//
//  Fed mono samples from the capture thread; analysis runs on a worker timer.
//

import Foundation
import Accelerate

final class KeyDetector {
    /// Called on the main queue when the estimated key changes (root, isMajor).
    var onKey: ((NoteName, Bool) -> Void)?

    private let sampleRate: Float
    private let log2n: vDSP_Length = 13           // 8192-point FFT
    private let n: Int
    private let fftSetup: FFTSetup
    private var window: [Float]

    private let ring = FloatRingBuffer(capacity: 1 << 18)
    private let queue = DispatchQueue(label: "com.livekaraoke.key")
    private var timer: DispatchSourceTimer?

    // Accumulated chroma across windows; smoothed toward stability.
    private var chroma = [Float](repeating: 0, count: 12)
    private var lastRoot: NoteName?
    private var lastMajor: Bool?

    // Krumhansl–Schmuckler tonal hierarchy profiles.
    private let majorProfile: [Float] = [6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88]
    private let minorProfile: [Float] = [6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17]

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        self.n = 1 << Int(log2n)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Producer side — capture audio thread.
    func appendMono(_ samples: UnsafeBufferPointer<Float>) { ring.write(samples) }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.analyze() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        for i in 0..<12 { chroma[i] = 0 }
        lastRoot = nil; lastMajor = nil
    }

    private func analyze() {
        guard ring.availableToRead >= n else { return }

        var samples = [Float](repeating: 0, count: n)
        samples.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(n))

        let half = n / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBytes { raw in
                    let cplx = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cplx.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Fold magnitude spectrum into 12 pitch classes.
        var frame = [Float](repeating: 0, count: 12)
        for k in 1..<half {
            let freq = Float(k) * sampleRate / Float(n)
            if freq < 55 || freq > 5000 { continue }  // A1..~D8
            let midi = 69 + 12 * log2(freq / 440)
            let pc = ((Int(midi.rounded()) % 12) + 12) % 12
            frame[pc] += magnitudes[k]
        }

        // Decay + accumulate for stability.
        for i in 0..<12 { chroma[i] = chroma[i] * 0.8 + frame[i] * 0.2 }

        let (root, isMajor) = bestKey(for: chroma)
        if root != lastRoot || isMajor != lastMajor {
            lastRoot = root; lastMajor = isMajor
            DispatchQueue.main.async { [weak self] in self?.onKey?(root, isMajor) }
        }
    }

    private func bestKey(for chroma: [Float]) -> (NoteName, Bool) {
        var bestCorr = -Float.greatestFiniteMagnitude
        var bestRoot = 0
        var bestMajor = true
        for tonic in 0..<12 {
            let maj = correlation(chroma, rotated(majorProfile, by: tonic))
            if maj > bestCorr { bestCorr = maj; bestRoot = tonic; bestMajor = true }
            let min = correlation(chroma, rotated(minorProfile, by: tonic))
            if min > bestCorr { bestCorr = min; bestRoot = tonic; bestMajor = false }
        }
        return (NoteName(rawValue: bestRoot) ?? .c, bestMajor)
    }

    private func rotated(_ p: [Float], by t: Int) -> [Float] {
        (0..<12).map { p[(($0 - t) % 12 + 12) % 12] }
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<12 {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let denom = (da * db).squareRoot()
        return denom > 0 ? num / denom : 0
    }
}
