//
//  AudioMonitor.swift
//  LiveKaraoke
//
//  The output engine. Two sources mixed to the default output:
//   • Instrumental: captured system audio with vocals removed. Two methods:
//       - band-split (RBJ biquads), run inline on the render thread (RT-safe)
//       - neural (Core ML), run on a worker thread and bridged via a mono ring
//         (keeps the slow model off the audio render thread; adds latency)
//   • Voice: the live microphone, pitch-corrected by the M2 autotune chain.
//
//  Use headphones — monitoring through speakers while capturing system audio
//  causes feedback, and the mic would re-capture the backing track.
//

import AVFoundation

final class AudioMonitor {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring: FloatRingBuffer
    private let sampleRate: Double

    // Vocal removal
    private let remover: VocalRemover
    private let method: SeparationMethod
    private let neural = NeuralSeparator()
    private var useNeural = false
    private var removeVocalsFlag: Bool
    private var neuralOutRing: FloatRingBuffer?
    private var neuralTimer: DispatchSourceTimer?
    private let neuralQueue = DispatchQueue(label: "com.livekaraoke.neural", qos: .userInitiated)

    // Voice
    private let voice = VoiceAutotune()
    private let instrumentalEnabled: Bool
    private let micEnabled: Bool

    private var deallocScratch: (() -> Void)?

    var removeVocals: Bool {
        get { removeVocalsFlag }
        set { removeVocalsFlag = newValue; remover.enabled = newValue }
    }

    init(ring: FloatRingBuffer,
         sampleRate: Double,
         removeVocals: Bool,
         method: SeparationMethod,
         instrumentalEnabled: Bool,
         micEnabled: Bool,
         scale: MusicScale,
         autotuneEnabled: Bool,
         retuneStrength: Float) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.remover = VocalRemover(sampleRate: sampleRate)
        self.remover.enabled = removeVocals
        self.removeVocalsFlag = removeVocals
        self.method = method
        self.instrumentalEnabled = instrumentalEnabled
        self.micEnabled = micEnabled
        self.voice.scale = scale
        self.voice.enabled = autotuneEnabled
        self.voice.strength = retuneStrength
    }

    /// True only if neural was requested AND a model is actually loaded.
    var neuralActive: Bool { method == .neural && neural.isAvailable }

    // MARK: live updates from the UI
    func updateScale(_ scale: MusicScale) { voice.scale = scale }
    func setAutotuneEnabled(_ on: Bool) { voice.enabled = on }
    func setRetuneStrength(_ s: Float) { voice.strength = s }

    func start() throws {
        if instrumentalEnabled {
            useNeural = neuralActive
            try attachInstrumental()
            if useNeural { startNeuralWorker() }
        }
        if micEnabled { try voice.attach(to: engine) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        stopNeuralWorker()
        engine.stop()
        if micEnabled { voice.detach() }
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        deallocScratch?()
        deallocScratch = nil
    }

    // MARK: instrumental source
    private func attachInstrumental() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 1) else {
            throw NSError(domain: "LiveKaraoke", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad monitor format"])
        }

        let ring = self.ring
        let remover = self.remover
        let useNeural = self.useNeural
        let maxFrames = 4096
        let stereoScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: maxFrames * 2)
        stereoScratch.initialize(repeating: 0)
        self.deallocScratch = { stereoScratch.deallocate() }

        if useNeural {
            self.neuralOutRing = FloatRingBuffer(capacity: 1 << 16)
        }
        let neuralOut = self.neuralOutRing

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buf = abl.first,
                  let out = buf.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let n = Int(frameCount)
            let want = min(n, maxFrames)

            if useNeural, let neuralOut {
                // Neural path: the worker already produced mono instrumental.
                neuralOut.read(into: UnsafeMutableBufferPointer(start: out, count: want))
            } else {
                // Band-split path: read stereo and process inline.
                let slice = UnsafeMutableBufferPointer(start: stereoScratch.baseAddress, count: want * 2)
                ring.read(into: slice)
                let removing = self?.removeVocalsFlag ?? true
                for f in 0..<want {
                    let l = stereoScratch[f * 2], r = stereoScratch[f * 2 + 1]
                    out[f] = removing ? remover.process(left: l, right: r) : (l + r) * 0.5
                }
            }
            if want < n { for f in want..<n { out[f] = 0 } }
            return noErr
        }
        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    // MARK: neural worker (consumes the capture ring, fills neuralOutRing)
    private func startNeuralWorker() {
        let block = neural.blockSize
        let ring = self.ring
        guard let outRing = neuralOutRing else { return }

        let stereo = UnsafeMutableBufferPointer<Float>.allocate(capacity: block * 2)
        let mono = UnsafeMutableBufferPointer<Float>.allocate(capacity: block)
        stereo.initialize(repeating: 0); mono.initialize(repeating: 0)

        // Run a little faster than real time so the output ring stays fed.
        let interval = Double(block) / sampleRate * 0.5
        let timer = DispatchSource.makeTimerSource(queue: neuralQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            while ring.availableToRead >= block * 2 {
                ring.read(into: stereo)
                if self.removeVocalsFlag {
                    self.neural.process(stereoInterleaved: UnsafeBufferPointer(stereo),
                                        out: mono)
                } else {
                    for f in 0..<block { mono[f] = (stereo[f * 2] + stereo[f * 2 + 1]) * 0.5 }
                }
                outRing.write(UnsafeBufferPointer(mono))
            }
        }
        neuralTimer = timer
        timer.resume()

        // Free scratch when the worker stops.
        let priorDealloc = self.deallocScratch
        self.deallocScratch = { priorDealloc?(); stereo.deallocate(); mono.deallocate() }
    }

    private func stopNeuralWorker() {
        neuralTimer?.cancel()
        neuralTimer = nil
        neuralOutRing = nil
    }
}
