//
//  Presets.swift
//  LiveKaraoke — M5
//
//  Quick autotune character presets, plus persistence of the last-used settings.
//

import Foundation

struct AutotunePreset: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let autotuneEnabled: Bool
    let retuneStrength: Float

    static let all: [AutotunePreset] = [
        .init(name: "Off",      autotuneEnabled: false, retuneStrength: 0.0),
        .init(name: "Gentle",   autotuneEnabled: true,  retuneStrength: 0.45),
        .init(name: "Natural",  autotuneEnabled: true,  retuneStrength: 0.7),
        .init(name: "Hard (T-Pain)", autotuneEnabled: true, retuneStrength: 1.0),
    ]
}

/// Lightweight persistence of user settings via UserDefaults.
enum SettingsStore {
    private static let d = UserDefaults.standard

    static func saveRetune(_ v: Float)            { d.set(v, forKey: "retuneStrength") }
    static func saveAutotune(_ v: Bool)           { d.set(v, forKey: "autotuneEnabled") }
    static func saveRemoveVocals(_ v: Bool)       { d.set(v, forKey: "removeVocals") }
    static func saveScaleRoot(_ v: Int)           { d.set(v, forKey: "scaleRoot") }
    static func saveScaleType(_ v: String)        { d.set(v, forKey: "scaleType") }

    static var retune: Float?       { d.object(forKey: "retuneStrength") as? Float }
    static var autotune: Bool?      { d.object(forKey: "autotuneEnabled") as? Bool }
    static var removeVocals: Bool?  { d.object(forKey: "removeVocals") as? Bool }
    static var scaleRoot: Int?      { d.object(forKey: "scaleRoot") as? Int }
    static var scaleType: String?   { d.string(forKey: "scaleType") }
}
