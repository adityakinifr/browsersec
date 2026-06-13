//
//  MusicScale.swift
//  LiveKaraoke — M2
//
//  Snaps a detected frequency to the nearest note allowed by a key + scale.
//  Drives autotune: target = snap(detectedF0); shift the voice toward target.
//

import Foundation

enum ScaleType: String, CaseIterable, Identifiable {
    case chromatic = "Chromatic"
    case major = "Major"
    case minor = "Natural Minor"

    var id: String { rawValue }

    /// Semitone offsets from the root, within an octave.
    var intervals: [Int] {
        switch self {
        case .chromatic: return Array(0..<12)
        case .major:     return [0, 2, 4, 5, 7, 9, 11]
        case .minor:     return [0, 2, 3, 5, 7, 8, 10]
        }
    }
}

enum NoteName: Int, CaseIterable, Identifiable {
    case c = 0, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b
    var id: Int { rawValue }
    var label: String {
        ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][rawValue]
    }
}

struct MusicScale {
    var root: NoteName = .c
    var type: ScaleType = .chromatic

    /// Allowed pitch classes (0–11) for this key/scale.
    private var allowedPitchClasses: Set<Int> {
        Set(type.intervals.map { ($0 + root.rawValue) % 12 })
    }

    private static func hzToMidi(_ hz: Float) -> Float { 69 + 12 * log2(hz / 440) }
    private static func midiToHz(_ m: Float) -> Float { 440 * pow(2, (m - 69) / 12) }

    /// Nearest in-key frequency to `hz`. Returns `hz` unchanged if input invalid.
    func snap(_ hz: Float) -> Float {
        guard hz > 0 else { return hz }
        let midi = MusicScale.hzToMidi(hz)
        let nearestInt = Int(midi.rounded())
        let allowed = allowedPitchClasses

        // Search outward from the nearest integer MIDI note for an allowed pitch class.
        for delta in 0...12 {
            for cand in [nearestInt - delta, nearestInt + delta] {
                if allowed.contains(((cand % 12) + 12) % 12) {
                    return MusicScale.midiToHz(Float(cand))
                }
            }
        }
        return hz
    }
}
