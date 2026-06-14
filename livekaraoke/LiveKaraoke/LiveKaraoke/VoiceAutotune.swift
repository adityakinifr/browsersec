//
//  VoiceAutotune.swift
//  LiveKaraoke — M2
//
//  Real-time pitch correction for the live microphone. We detect the singer's
//  f0 from the mic, snap it to the nearest in-key note, and drive an
//  AVAudioUnitTimePitch by the required cents.
//
//  Architecture (important): the mic is captured on a DEDICATED, tap-only
//  AVAudioEngine and pushed into a ring. The autotune (timePitch) and playback
//  live in the OUTPUT engine via an AVAudioSourceNode that reads that ring.
//
//  Why: on macOS a single AVAudioEngine binds input+output to one device. Routing
//  the mic *through to the output* in one engine throws an uncatchable ObjC
//  exception (AUGraphParser InitializeActiveNodesInInputChain) whenever the input
//  and output devices differ — which crashed the app. A tap-only input engine is
//  the supported mic-capture pattern and never routes input→output, so it's safe;
//  the output engine only ever sees source nodes (no inputNode), so it can't hit
//  that input-chain failure.
//

import AVFoundation

final class VoiceAutotune {
    let timePitch = AVAudioUnitTimePitch()   // lives in the OUTPUT engine

    var enabled = true
    var strength: Float = 1.0           // 0 = off, 1 = full snap
    var scale = MusicScale()

    private var detector: PitchDetector?
    private var smoothedCents: Float = 0

    private let inputEngine = AVAudioEngine()         // tap-only mic capture
    private let micRing = FloatRingBuffer(capacity: 1 << 15)
    private var sourceNode: AVAudioSourceNode?
    private var capturing = false

    /// Reads the mic's hardware format without starting anything. nil if no input.
    private func micFormat() -> AVAudioFormat? {
        let fmt = inputEngine.inputNode.inputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { return nil }
        return fmt
    }

    /// Build mic-source -> timePitch -> mixer in the OUTPUT engine (no inputNode
    /// there, so it can't trigger the input-chain crash). Returns false if there
    /// is no usable mic — in which case nothing is attached. Call before the
    /// output engine starts.
    func attach(to output: AVAudioEngine) -> Bool {
        guard let fmt = micFormat(),
              let monoFmt = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate,
                                          channels: 1) else {
            return false
        }
        detector = PitchDetector(sampleRate: fmt.sampleRate)

        let ring = micRing
        let node = AVAudioSourceNode(format: monoFmt) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let out = abl.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            ring.read(into: UnsafeMutableBufferPointer(start: out, count: Int(frameCount)))
            return noErr
        }
        sourceNode = node
        output.attach(node)
        output.attach(timePitch)
        output.connect(node, to: timePitch, format: monoFmt)
        output.connect(timePitch, to: output.mainMixerNode, format: monoFmt)
        return true
    }

    /// Start mic capture on the dedicated input engine (tap only — safe to run
    /// off the main thread). Must be called after `attach` returned true.
    func startCapture() throws {
        let input = inputEngine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.channelCount > 0 else {
            throw NSError(domain: "LiveKaraoke", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.captureTap(buffer)
        }
        inputEngine.prepare()
        try inputEngine.start()
        capturing = true
    }

    func stopCapture() {
        if capturing {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputEngine.stop()
            capturing = false
        }
        detector = nil
    }

    func detach(from output: AVAudioEngine) {
        if let sourceNode { output.detach(sourceNode) }
        if timePitch.engine != nil { output.detach(timePitch) }
        sourceNode = nil
    }

    // MARK: live updates
    func setEnabled(_ on: Bool) { enabled = on }

    /// Runs on the input tap thread: push mic to the ring + drive the correction.
    private func captureTap(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        micRing.write(UnsafeBufferPointer(start: ch[0], count: n))
        analyze(ch[0], count: n)
    }

    private func analyze(_ ptr: UnsafePointer<Float>, count n: Int) {
        guard enabled, strength > 0, let detector else {
            // When disabled, glide correction back to zero so the voice is dry.
            smoothedCents += (0 - smoothedCents) * 0.4
            timePitch.pitch = smoothedCents
            return
        }
        let f0 = detector.detect(UnsafeBufferPointer(start: ptr, count: n))
        guard f0 > 0 else { return }     // unvoiced: hold last correction

        let target = scale.snap(f0)
        let cents = 1200 * log2(target / f0)
        let desired = max(-1200, min(1200, cents)) * strength
        smoothedCents += (desired - smoothedCents) * 0.4
        timePitch.pitch = smoothedCents
    }
}
