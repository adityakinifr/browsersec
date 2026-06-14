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

/// Real-time spectrum for the UI meter: log-spaced frequency bands, each
/// normalized to 0…1 with an attack/decay envelope so the bars rise fast and
/// fall smoothly. Fed mono from the capture thread; analyzed on a worker and
/// delivered to the main actor via `onBands`.
final class SpectrumAnalyzer {
    /// Called on the main queue ~45×/s with `bandCount` values in 0…1.
    var onBands: (([Float]) -> Void)?

    let bandCount: Int
    private let sampleRate: Float
    private let log2n: vDSP_Length = 11        // 2048-point FFT
    private let n: Int
    private let fftSetup: FFTSetup
    private var window: [Float]

    private let ring = FloatRingBuffer(capacity: 1 << 16)
    private let queue = DispatchQueue(label: "com.livekaraoke.spectrum", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var slide: [Float]                 // sliding window of last n samples
    private var bandLo: [Int]                  // first bin of each band
    private var bandHi: [Int]                  // last bin of each band
    private var env: [Float]                   // smoothed per-band envelope 0…1

    // FFT scratch
    private var realp: [Float]; private var imagp: [Float]; private var mags: [Float]

    init(sampleRate: Double, bandCount: Int = 28) {
        self.sampleRate = Float(sampleRate)
        self.bandCount = bandCount
        self.n = 1 << Int(log2n)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        self.slide = [Float](repeating: 0, count: n)
        self.env = [Float](repeating: 0, count: bandCount)
        let half = n / 2
        self.realp = [Float](repeating: 0, count: half)
        self.imagp = [Float](repeating: 0, count: half)
        self.mags = [Float](repeating: 0, count: half)

        // Log-spaced band edges from 40 Hz to 16 kHz.
        let fLo: Float = 40, fHi: Float = 16_000
        var lo = [Int](), hi = [Int]()
        for b in 0..<bandCount {
            let f0 = fLo * powf(fHi / fLo, Float(b) / Float(bandCount))
            let f1 = fLo * powf(fHi / fLo, Float(b + 1) / Float(bandCount))
            let b0 = max(1, min(half - 1, Int(f0 / self.sampleRate * Float(n))))
            let b1 = max(b0, min(half - 1, Int(f1 / self.sampleRate * Float(n))))
            lo.append(b0); hi.append(b1)
        }
        self.bandLo = lo; self.bandHi = hi
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Producer — capture audio thread.
    func appendMono(_ samples: UnsafeBufferPointer<Float>) { ring.write(samples) }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 1.0 / 45.0)
        t.setEventHandler { [weak self] in self?.analyze() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        for i in 0..<bandCount { env[i] = 0 }
        for i in 0..<n { slide[i] = 0 }
    }

    private func analyze() {
        // Pull the freshest n samples into the sliding window (discard backlog).
        var avail = ring.availableToRead
        if avail <= 0 {
            // No new audio: decay the bars toward silence and report.
            decayAndReport(target: nil); return
        }
        if avail > n { // catch up: drop all but the last n samples
            let drop = avail - n
            var scratch = [Float](repeating: 0, count: drop)
            scratch.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            avail = n
        }
        let take = min(avail, n)
        let keep = n - take
        for i in 0..<keep { slide[i] = slide[i + take] }
        slide.withUnsafeMutableBufferPointer { buf in
            let tail = UnsafeMutableBufferPointer(start: buf.baseAddress! + keep, count: take)
            ring.read(into: tail)
        }

        // Windowed real FFT → magnitudes.
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(slide, 1, window, 1, &windowed, 1, vDSP_Length(n))
        let half = n / 2
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let cplx = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cplx.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // Per band: peak magnitude → dB → normalized 0…1.
        var target = [Float](repeating: 0, count: bandCount)
        let norm = 2.0 / Float(n)
        for b in 0..<bandCount {
            var peak: Float = 0
            for k in bandLo[b]...bandHi[b] { peak = max(peak, mags[k]) }
            let db = 20 * log10f(peak * norm + 1e-7)
            // Map roughly [-70 dB … -6 dB] to [0 … 1], with a slight tilt so
            // higher bands (quieter by nature) still register visually.
            let tilt = 1 + 0.6 * Float(b) / Float(bandCount)
            target[b] = max(0, min(1, (db + 70) / 64)) * tilt
        }
        decayAndReport(target: target)
    }

    private func decayAndReport(target: [Float]?) {
        for b in 0..<bandCount {
            let t = target?[b] ?? 0
            // Near-instant attack, quick decay — sharp, responsive bars.
            if t > env[b] { env[b] = t }
            else { env[b] += (t - env[b]) * 0.4 }
            env[b] = min(1, max(0, env[b]))
        }
        let snapshot = env
        DispatchQueue.main.async { [weak self] in self?.onBands?(snapshot) }
    }
}
