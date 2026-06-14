//
//  NeuralSeparator.swift
//  LiveKaraoke — M4
//
//  Higher-quality vocal removal via a Core ML source-separation model, run
//  block-by-block off the render thread. This is the quality tier of the
//  design's "two latency domains": neural adds latency, so it lives on the
//  backing-track path only (never in the singer's monitoring loop).
//
//  The model is NOT bundled (it's large and license-bound). Convert one with
//  `tools/convert_separator_coreml.py` and drop `VocalSeparator.mlpackage` into
//  the app target. Until then `isAvailable == false` and the app uses the
//  band-split remover.
//
//  Expected model contract (see tools/README.md):
//    input  "audioIn"  : MLMultiArray  Float32  shape [1, 2, blockSize]  (L,R)
//    output "accompaniment" : MLMultiArray Float32 shape [1, 2, blockSize]
//

import Foundation
import CoreML
import Accelerate

enum SeparationMethod: String, CaseIterable, Identifiable {
    case bandSplit = "Band-split (fast)"
    case spectral = "Spectral (HQ)"
    case neural = "Neural (Core ML)"
    var id: String { rawValue }
}

/// Frequency-domain vocal suppression (STFT + per-bin soft mask).
///
/// Lead vocals are mixed dead-center, so they appear as *correlated* energy in
/// L and R. For each frequency bin we measure the L/R correlation and attenuate
/// the correlated (centered) part while keeping uncorrelated/panned energy —
/// i.e. the instruments. Because the decision is per-bin and frequency-selective
/// (not a broadband time-domain subtraction), it removes far more of the vocal
/// with much less of the "hollow" artifact, and it keeps full stereo.
///
/// Streaming STFT: Hann window, 75% overlap (hop = N/4), overlap-add resynthesis.
/// Runs inline on the render thread (a few small FFTs per hop). Adds ~one window
/// of latency (~21 ms at 48 kHz, N = 1024) — fine on the backing-track path.
final class SpectralSeparator {
    var enabled = true
    /// 0…1.5 from the UI. Higher = more aggressive vocal removal.
    var strength: Float = 1.0

    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let hop = 256
    private let sampleRate: Float

    // Protect centered bass and extreme highs (kept at unity) so the kick/bass
    // and air stay full — only the vocal range is masked.
    private var loBin = 1
    private var hiBin = 512

    private let fftSetup: FFTSetup
    private var window: [Float]
    private let scale: Float        // FFT + COLA normalization

    // Sliding analysis buffers (last N samples) per channel.
    private var anaL: [Float]; private var anaR: [Float]
    // Staging of the next `hop` input samples.
    private var stageL: [Float]; private var stageR: [Float]
    private var stageCount = 0
    // Overlap-add synthesis accumulators.
    private var olaL: [Float]; private var olaR: [Float]
    // Output FIFOs bridging hop-sized production to arbitrary render sizes.
    private let outL = FloatRingBuffer(capacity: 1 << 14)
    private let outR = FloatRingBuffer(capacity: 1 << 14)

    // FFT scratch (allocated once; no allocation on the audio thread).
    private var reL: [Float]; private var imL: [Float]
    private var reR: [Float]; private var imR: [Float]
    private var frame: [Float]; private var timeL: [Float]; private var timeR: [Float]

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: n)
        // Plain Hann (not normalized): with 75% overlap, Σ window² = 1.5 (COLA).
        vDSP_hann_window(&window, vDSP_Length(n), 0)
        // zrip forward∘inverse scales by 2N; the w² overlap-add adds ×1.5.
        self.scale = 1.0 / (3.0 * Float(n))
        self.anaL = [Float](repeating: 0, count: n)
        self.anaR = [Float](repeating: 0, count: n)
        self.stageL = [Float](repeating: 0, count: hop)
        self.stageR = [Float](repeating: 0, count: hop)
        self.olaL = [Float](repeating: 0, count: n)
        self.olaR = [Float](repeating: 0, count: n)
        let half = n / 2
        self.reL = [Float](repeating: 0, count: half)
        self.imL = [Float](repeating: 0, count: half)
        self.reR = [Float](repeating: 0, count: half)
        self.imR = [Float](repeating: 0, count: half)
        self.frame = [Float](repeating: 0, count: n)
        self.timeL = [Float](repeating: 0, count: n)
        self.timeR = [Float](repeating: 0, count: n)
        // Protect the low end (bass, kick, centered low instruments) and the
        // extreme highs so the instrumental keeps its body and air — only the
        // vocal core is masked. Raising the low edge to ~250 Hz noticeably
        // restores instrumental fullness at negligible vocal cost (little vocal
        // energy lives below 250 Hz).
        self.loBin = max(1, Int(250.0 / self.sampleRate * Float(n)))
        self.hiBin = min(half - 1, Int(16000.0 / self.sampleRate * Float(n)))
        primeOutputCushion()
    }

    /// Production happens in fixed `hop`-sized bursts, but the render pulls
    /// arbitrary block sizes. Pre-fill the output FIFOs with one window of
    /// silence so a non-hop-multiple read never underruns (which would zero-pad
    /// mid-stream and garble the audio). Costs ~one window of extra latency.
    private func primeOutputCushion() {
        let cushion = [Float](repeating: 0, count: n)
        cushion.withUnsafeBufferPointer { outL.write($0); outR.write($0) }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func reset() {
        for i in 0..<n { anaL[i] = 0; anaR[i] = 0; olaL[i] = 0; olaR[i] = 0 }
        stageCount = 0
    }

    /// Process one interleaved-stereo block; write stereo instrumental to outL/outR.
    func process(stereoInterleaved input: UnsafePointer<Float>, frames: Int,
                 outL outPtrL: UnsafeMutablePointer<Float>,
                 outR outPtrR: UnsafeMutablePointer<Float>) {
        if !enabled {
            for f in 0..<frames { outPtrL[f] = input[f * 2]; outPtrR[f] = input[f * 2 + 1] }
            return
        }
        for f in 0..<frames {
            stageL[stageCount] = input[f * 2]
            stageR[stageCount] = input[f * 2 + 1]
            stageCount += 1
            if stageCount == hop { processFrame(); stageCount = 0 }
        }
        outL.read(into: UnsafeMutableBufferPointer(start: outPtrL, count: frames))
        outR.read(into: UnsafeMutableBufferPointer(start: outPtrR, count: frames))
    }

    private func processFrame() {
        // Slide analysis windows: drop oldest `hop`, append the staged `hop`.
        let keep = n - hop
        for i in 0..<keep { anaL[i] = anaL[i + hop]; anaR[i] = anaR[i + hop] }
        for i in 0..<hop { anaL[keep + i] = stageL[i]; anaR[keep + i] = stageR[i] }

        forwardFFT(anaL, &reL, &imL)
        forwardFFT(anaR, &reR, &imR)

        // Lower exponent = more aggressive. strength 0→p≈2 (gentle), 1.5→p≈0.5.
        let p = max(0.3, 2.0 - strength)
        let eps: Float = 1e-9
        for k in loBin...hiBin {
            let lr = reL[k] * reR[k] + imL[k] * imR[k]      // Re(L·conj R)
            let pl = reL[k] * reL[k] + imL[k] * imL[k]      // |L|²
            let pr = reR[k] * reR[k] + imR[k] * imR[k]      // |R|²
            let s = (2 * lr) / (pl + pr + eps)              // ≈1 centered, ≈0 panned
            let g = 1 - powf(max(0, s), p)                  // keep panned, drop centered
            reL[k] *= g; imL[k] *= g; reR[k] *= g; imR[k] *= g
        }

        // In-place inverse (destroys reL/imL/reR/imR, recomputed next frame).
        inverseFFT(&reL, &imL, &timeL)
        inverseFFT(&reR, &imR, &timeR)

        // Synthesis window + normalize + overlap-add, then emit `hop` samples.
        for i in 0..<n {
            olaL[i] += timeL[i] * window[i] * scale
            olaR[i] += timeR[i] * window[i] * scale
        }
        olaL.withUnsafeBufferPointer { outL.write(UnsafeBufferPointer(rebasing: $0[0..<hop])) }
        olaR.withUnsafeBufferPointer { outR.write(UnsafeBufferPointer(rebasing: $0[0..<hop])) }
        for i in 0..<keep { olaL[i] = olaL[i + hop]; olaR[i] = olaR[i + hop] }
        for i in keep..<n { olaL[i] = 0; olaR[i] = 0 }
    }

    private func forwardFFT(_ src: [Float], _ re: inout [Float], _ im: inout [Float]) {
        // Window the time frame, then real-FFT into split complex (re/im).
        vDSP_vmul(src, 1, window, 1, &frame, 1, vDSP_Length(n))
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { raw in
                    let cplx = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cplx.baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    private func inverseFFT(_ re: inout [Float], _ im: inout [Float], _ out: inout [Float]) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBytes { raw in
                    let cplx = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ztoc(&split, 1, cplx.baseAddress!, 2, vDSP_Length(n / 2))
                }
            }
        }
    }
}

final class NeuralSeparator {
    /// Frames per inference call. Must match the converted model's window.
    let blockSize = 1024

    private let model: MLModel?
    private let inputName = "audioIn"
    private let outputName = "accompaniment"
    private var inputArray: MLMultiArray?

    var isAvailable: Bool { model != nil }

    init() {
        // Look for a compiled or packaged model in the app bundle.
        let candidates = ["VocalSeparator"]
        var loaded: MLModel?
        let config = MLModelConfiguration()
        config.computeUnits = .all      // prefer the Neural Engine
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: name, withExtension: "mlpackage") {
                loaded = try? MLModel(contentsOf: url, configuration: config)
                if loaded != nil { break }
            }
        }
        self.model = loaded
        if loaded != nil {
            self.inputArray = try? MLMultiArray(
                shape: [1, 2, NSNumber(value: blockSize)], dataType: .float32)
        }
    }

    func reset() { /* stateless block model; nothing to reset */ }

    /// One stereo block (interleaved L,R, `blockSize` frames) -> mono instrumental.
    /// Falls back to a plain downmix if the model is unavailable or errors.
    func process(stereoInterleaved input: UnsafeBufferPointer<Float>,
                 out: UnsafeMutableBufferPointer<Float>) {
        guard let model, let inputArray else {
            downmix(input, into: out); return
        }

        // Pack interleaved [L,R,...] into channels-first [1,2,N].
        let ptr = inputArray.dataPointer.bindMemory(to: Float.self, capacity: 2 * blockSize)
        for f in 0..<blockSize {
            ptr[f] = input[f * 2]                 // channel 0 (L)
            ptr[blockSize + f] = input[f * 2 + 1] // channel 1 (R)
        }

        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
            let result = try model.prediction(from: provider)
            guard let acc = result.featureValue(for: outputName)?.multiArrayValue else {
                downmix(input, into: out); return
            }
            let a = acc.dataPointer.bindMemory(to: Float.self, capacity: 2 * blockSize)
            // Downmix the accompaniment stereo output to mono.
            for f in 0..<blockSize {
                out[f] = (a[f] + a[blockSize + f]) * 0.5
            }
        } catch {
            downmix(input, into: out)
        }
    }

    private func downmix(_ input: UnsafeBufferPointer<Float>,
                         into out: UnsafeMutableBufferPointer<Float>) {
        for f in 0..<blockSize {
            out[f] = (input[f * 2] + input[f * 2 + 1]) * 0.5
        }
    }
}
