//
//  VoiceAutotune.swift
//  LiveKaraoke — M2
//
//  Real-time pitch correction for the live microphone. We detect the singer's
//  f0 from an analysis tap, snap it to the nearest in-key note, and drive an
//  AVAudioUnitTimePitch in the signal path by the required cents.
//
//  NOTE: AVAudioUnitTimePitch is a convenient, decent-quality shifter but adds
//  some latency and the correction (tap-driven) lags the live stream slightly.
//  Good enough to prove autotune for M2; M5 can swap in a tighter PSOLA path.
//

import AVFoundation

final class VoiceAutotune {
    let timePitch = AVAudioUnitTimePitch()

    var enabled = true
    var strength: Float = 1.0           // 0 = off, 1 = full snap
    var scale = MusicScale()

    private var detector: PitchDetector?
    private var smoothedCents: Float = 0
    private weak var engine: AVAudioEngine?

    /// Inserts input -> timePitch -> mixer and installs the analysis tap.
    func attach(to engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            throw NSError(domain: "LiveKaraoke", code: -2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "No microphone input available"])
        }

        detector = PitchDetector(sampleRate: fmt.sampleRate)

        engine.attach(timePitch)
        engine.connect(input, to: timePitch, format: fmt)
        engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)

        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buffer, _ in
            self?.analyze(buffer)
        }
        self.engine = engine
    }

    func detach() {
        engine?.inputNode.removeTap(onBus: 0)
        if let engine, timePitch.engine != nil { engine.detach(timePitch) }
        engine = nil
        detector = nil
    }

    /// Runs on the input tap thread.
    private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard enabled, strength > 0,
              let detector,
              let ch = buffer.floatChannelData else {
            // When disabled, glide correction back to zero so the voice is dry.
            smoothedCents += (0 - smoothedCents) * 0.4
            timePitch.pitch = smoothedCents
            return
        }
        let n = Int(buffer.frameLength)
        let f0 = detector.detect(UnsafeBufferPointer(start: ch[0], count: n))
        guard f0 > 0 else { return }     // unvoiced: hold last correction

        let target = scale.snap(f0)
        let cents = 1200 * log2(target / f0)
        let desired = max(-1200, min(1200, cents)) * strength
        // Retune speed: bigger factor = faster (more "hard" autotune).
        smoothedCents += (desired - smoothedCents) * 0.4
        timePitch.pitch = smoothedCents
    }
}
