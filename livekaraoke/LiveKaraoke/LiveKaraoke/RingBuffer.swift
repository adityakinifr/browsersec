//
//  RingBuffer.swift
//  LiveKaraoke
//
//  A single-producer / single-consumer (SPSC) lock-free ring buffer of Float.
//  The audio-capture IOProc is the sole producer; the monitor render block is
//  the sole consumer. On Apple Silicon, naturally-aligned word-sized loads and
//  stores are atomic, so the plain Int read/write indices below are safe for
//  the SPSC case without explicit locks.  (Spike-grade: revisit with the
//  Synchronization framework's `Atomic` if we raise the deployment target.)
//

import Foundation

final class FloatRingBuffer {
    private let capacity: Int
    private let storage: UnsafeMutableBufferPointer<Float>

    // Producer writes `writeIndex`, reads `readIndex`.
    // Consumer writes `readIndex`, reads `writeIndex`.
    private var writeIndex: Int = 0
    private var readIndex: Int = 0

    init(capacity: Int) {
        // Round up to a power of two so we can mask instead of modulo.
        var cap = 1
        while cap < capacity { cap <<= 1 }
        self.capacity = cap
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    private var mask: Int { capacity - 1 }

    /// Producer side. Drops samples if the buffer is full (monitor not keeping up).
    func write(_ samples: UnsafeBufferPointer<Float>) {
        let w = writeIndex
        let r = readIndex
        let available = capacity - (w - r)
        let count = Swift.min(samples.count, available)
        for i in 0..<count {
            storage[(w + i) & mask] = samples[i]
        }
        writeIndex = w + count
    }

    /// Consumer side. Fills `out`; zero-pads any underrun.
    func read(into out: UnsafeMutableBufferPointer<Float>) {
        let w = writeIndex
        let r = readIndex
        let available = w - r
        let count = Swift.min(out.count, available)
        for i in 0..<count {
            out[i] = storage[(r + i) & mask]
        }
        for i in count..<out.count {
            out[i] = 0
        }
        readIndex = r + count
    }
}
