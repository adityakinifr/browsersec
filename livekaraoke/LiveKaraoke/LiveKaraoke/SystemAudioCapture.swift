//
//  SystemAudioCapture.swift
//  LiveKaraoke
//
//  M0 spike: capture *all* system audio using the native Core Audio process-tap
//  API (macOS 14.4+), compute an RMS level for a meter, and feed mono samples
//  into a ring buffer for the optional passthrough monitor.
//
//  Flow:
//    1. CATapDescription(stereoGlobalTapButExcludeProcesses: [])  -> tap whole system
//    2. AudioHardwareCreateProcessTap(...)                        -> tapID
//    3. read tap format (kAudioTapPropertyFormat) + UID (kAudioTapPropertyUID)
//    4. AudioHardwareCreateAggregateDevice([...tap...])           -> aggregateID
//    5. AudioDeviceCreateIOProcIDWithBlock(...)                   -> IO callback
//    6. AudioDeviceStart(...)                                     -> samples flow
//
//  Modeled on Apple's "Capturing system audio with Core Audio taps" sample.
//  This is hardware-touching code that cannot be compiled on CI here; expect to
//  iterate slightly on first on-device build.
//

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

@MainActor
final class SystemAudioCapture: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0      // 0...1 RMS, smoothed
    @Published var monitorEnabled = false
    @Published private(set) var status = "Idle"

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var ring = FloatRingBuffer(capacity: 1 << 16)
    private var monitor: AudioMonitor?
    private var sampleRate: Double = 48_000

    // Written on the audio thread, read on a UI timer. Plain Float: aligned
    // word access is atomic on arm64, good enough for a meter.
    private var rawLevel: Float = 0
    private var levelTimer: Timer?

    // MARK: - Public control

    func start() {
        guard !isRunning else { return }
        do {
            try setUpTap()
            try setUpAggregateDevice()
            try setUpIOProc()
            try AudioDeviceStartChecked()
            if monitorEnabled {
                let m = AudioMonitor(ring: ring, sampleRate: sampleRate)
                try m.start()
                monitor = m
            }
            startLevelTimer()
            isRunning = true
            status = "Capturing system audio @ \(Int(sampleRate)) Hz"
        } catch {
            status = "Start failed: \(error.localizedDescription)"
            tearDown()
        }
    }

    func stop() {
        guard isRunning else { return }
        tearDown()
        isRunning = false
        level = 0
        status = "Stopped"
    }

    // MARK: - Tap

    private func setUpTap() throws {
        // Tap every process' output, mixed to stereo, excluding none.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "LiveKaraoke System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted   // don't mute the original playback

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(desc, &newTap)
        guard err == noErr else { throw caError("AudioHardwareCreateProcessTap", err) }
        tapID = newTap

        // Pull the tap's stream format so the aggregate + monitor agree on rate.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let fmtErr = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        if fmtErr == noErr, asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }
    }

    private func tapUID() throws -> String {
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let err = withUnsafeMutablePointer(to: &cf) { ptr in
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw caError("kAudioTapPropertyUID", err) }
        return cf as String
    }

    // MARK: - Aggregate device

    private func setUpAggregateDevice() throws {
        let uid = try tapUID()
        let aggUID = "com.livekaraoke.aggregate.\(UUID().uuidString)"

        let tapList: [[String: Any]] = [[
            kAudioSubTapUIDKey as String: uid,
            kAudioSubTapDriftCompensationKey as String: true
        ]]

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "LiveKaraoke Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapListKey as String: tapList,
            kAudioAggregateDeviceTapAutoStartKey as String: true
        ]

        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAgg)
        guard err == noErr else { throw caError("AudioHardwareCreateAggregateDevice", err) }
        aggregateID = newAgg
    }

    // MARK: - IOProc

    private func setUpIOProc() throws {
        let queue = DispatchQueue(label: "com.livekaraoke.capture", qos: .userInteractive)

        let block: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.handle(inputData: inInputData)
        }

        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, block)
        guard err == noErr, let procID else {
            throw caError("AudioDeviceCreateIOProcIDWithBlock", err)
        }
        ioProcID = procID
    }

    /// Runs on the capture queue (audio thread). Keep it allocation-free.
    private nonisolated func handle(inputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = abl.first,
              let raw = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            return
        }

        let channels = Int(firstBuffer.mNumberChannels == 0 ? 1 : firstBuffer.mNumberChannels)
        let totalFloats = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let frames = channels > 0 ? totalFloats / channels : totalFloats
        guard frames > 0 else { return }

        // Downmix to mono into a small stack scratch, compute RMS, push to ring.
        var sumSquares: Float = 0
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
        defer { scratch.deallocate() }

        if channels == 1 {
            for i in 0..<frames {
                let s = raw[i]
                scratch[i] = s
                sumSquares += s * s
            }
        } else {
            // Interleaved [L,R,L,R,...] -> mono average.
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<channels { acc += raw[f * channels + c] }
                let s = acc / Float(channels)
                scratch[f] = s
                sumSquares += s * s
            }
        }

        let rms = (sumSquares / Float(frames)).squareRoot()
        // Read-modify-write of a single aligned Float; fine for a meter.
        self.rawLevel = rms

        // Only fill the ring when someone is listening.
        if self.monitorEnabled {
            self.ring.write(UnsafeBufferPointer(scratch))
        }
    }

    // MARK: - Level metering (UI thread)

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Simple attack/decay smoothing for a nicer meter.
                let target = min(1, self.rawLevel * 3)   // scale up; system audio RMS is low
                let smoothing: Float = target > self.level ? 0.5 : 0.15
                self.level += (target - self.level) * smoothing
            }
        }
    }

    // MARK: - Start / teardown helpers

    private func AudioDeviceStartChecked() throws {
        let err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw caError("AudioDeviceStart", err) }
    }

    private func tearDown() {
        levelTimer?.invalidate(); levelTimer = nil
        monitor?.stop(); monitor = nil

        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        rawLevel = 0
        // Fresh ring for the next run.
        ring = FloatRingBuffer(capacity: 1 << 16)
    }

    private func caError(_ what: String, _ status: OSStatus) -> NSError {
        NSError(domain: "CoreAudio", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(what) failed (OSStatus \(status))"])
    }
}
