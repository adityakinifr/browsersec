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
    private let spectral: SpectralSeparator
    private let method: SeparationMethod
    private let neural = NeuralSeparator()
    private var useNeural = false
    private var useSpectral = false
    private var removeVocalsFlag: Bool
    private var neuralOutRing: FloatRingBuffer?
    private var neuralTimer: DispatchSourceTimer?
    private let neuralQueue = DispatchQueue(label: "com.livekaraoke.neural", qos: .userInitiated)

    // Voice
    private let voice = VoiceAutotune()
    private let instrumentalEnabled: Bool
    private let micEnabled: Bool
    // Mic engine start/stop runs here, off the main thread — AVAudioEngine.start()
    // can block on the Core Audio HAL, which would otherwise freeze the UI.
    private let voiceQueue = DispatchQueue(label: "com.livekaraoke.voice", qos: .userInitiated)

    private var deallocScratch: (() -> Void)?

    // Recording (M5)
    private var recordFile: AVAudioFile?
    private var isTapping = false

    var removeVocals: Bool {
        get { removeVocalsFlag }
        set { removeVocalsFlag = newValue; remover.enabled = newValue; spectral.enabled = newValue }
    }

    init(ring: FloatRingBuffer,
         sampleRate: Double,
         removeVocals: Bool,
         removalStrength: Float,
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
        self.remover.strength = removalStrength
        self.spectral = SpectralSeparator(sampleRate: sampleRate)
        self.spectral.enabled = removeVocals
        self.spectral.strength = removalStrength
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
    func setRemovalStrength(_ s: Float) { remover.strength = s; spectral.strength = s }
    func updateScale(_ scale: MusicScale) { voice.scale = scale }
    func setAutotuneEnabled(_ on: Bool) { voice.enabled = on }
    func setRetuneStrength(_ s: Float) { voice.strength = s }

    func start() throws {
        if instrumentalEnabled {
            useNeural = neuralActive
            useSpectral = (method == .spectral) && !useNeural
            try attachInstrumental()
            if useNeural { startNeuralWorker() }
        }
        // Attach the mic graph (source -> timePitch -> mixer) to the OUTPUT engine
        // before starting it. No inputNode is involved here, so this can't trigger
        // the input-chain crash. Returns false (and attaches nothing) if no mic.
        var micAttached = false
        if micEnabled { micAttached = voice.attach(to: engine) }

        if instrumentalEnabled || micAttached {
            engine.prepare()
            try engine.start()
        }

        if micAttached {
            // Mic *capture* is a tap-only engine. Start it off the main thread:
            // AVAudioEngine.start() can block on the HAL. Non-fatal on failure —
            // the mic source node simply reads silence and the music plays on.
            voiceQueue.async { [weak self] in
                try? self?.voice.startCapture()
            }
        }
    }

    // MARK: recording the final mix
    /// Starts writing the mixer output to `url` (AAC .m4a). Returns false on error.
    @discardableResult
    func startRecording(to url: URL) -> Bool {
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        do {
            recordFile = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            return false
        }
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.recordFile?.write(from: buffer)
        }
        isTapping = true
        return true
    }

    func stopRecording() {
        if isTapping {
            engine.mainMixerNode.removeTap(onBus: 0)
            isTapping = false
        }
        recordFile = nil
    }

    func stop() {
        stopRecording()
        stopNeuralWorker()
        engine.stop()
        if micEnabled {
            voiceQueue.async { [voice] in voice.stopCapture() }
            voice.detach(from: engine)
        }
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        deallocScratch?()
        deallocScratch = nil
    }

    // MARK: instrumental source
    private func attachInstrumental() throws {
        // Stereo output: the remover keeps both channels, preserving the mix's
        // width and full frequency range (a mono downmix sounded muted/distant).
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 2) else {
            throw NSError(domain: "LiveKaraoke", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad monitor format"])
        }

        let ring = self.ring
        let remover = self.remover
        let spectral = self.spectral
        let useNeural = self.useNeural
        let useSpectral = self.useSpectral
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
            // Non-interleaved stereo: one buffer per channel.
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let n = Int(frameCount)
            let want = min(n, maxFrames)

            if useNeural, let neuralOut {
                // Neural path: the worker produced a mono instrumental; fan it
                // out to both channels (the model is a separate, mono pipeline).
                let mono = UnsafeMutableBufferPointer(start: stereoScratch.baseAddress, count: want)
                neuralOut.read(into: mono)
                for f in 0..<want { outL[f] = mono[f]; outR[f] = mono[f] }
            } else if useSpectral {
                // Spectral path: STFT soft-mask, stereo in -> stereo out inline.
                let slice = UnsafeMutableBufferPointer(start: stereoScratch.baseAddress, count: want * 2)
                ring.read(into: slice)
                spectral.process(stereoInterleaved: stereoScratch.baseAddress!, frames: want,
                                 outL: outL, outR: outR)
            } else {
                // Band-split path: read interleaved stereo and process inline.
                let slice = UnsafeMutableBufferPointer(start: stereoScratch.baseAddress, count: want * 2)
                ring.read(into: slice)
                for f in 0..<want {
                    let (l, r) = remover.process(left: stereoScratch[f * 2],
                                                 right: stereoScratch[f * 2 + 1])
                    outL[f] = l; outR[f] = r
                }
            }
            if want < n { for f in want..<n { outL[f] = 0; outR[f] = 0 } }
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
