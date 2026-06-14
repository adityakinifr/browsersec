//
//  LyricsProvider.swift
//  LiveKaraoke — M3
//
//  Fetches time-synced (LRC) lyrics for an identified track from lrclib.net,
//  a free, key-less lyrics API, and parses the LRC into timed lines.
//
//  Network access depends on the environment policy. If no synced lyrics exist
//  for the track, returns nil and the UI shows a friendly message.
//

import Foundation
import AppKit

/// Reads the currently-playing track (title, artist, album art) directly from the
/// Spotify desktop app via AppleScript. Independent of ShazamKit — gives real
/// Spotify metadata and artwork. Requires the one-time "control Spotify"
/// automation permission (NSAppleEventsUsageDescription drives the prompt).
@MainActor
final class NowPlaying: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var artwork: NSImage?
    @Published var playing = false

    /// Called each poll with (title, artist, playbackPosition, isPlaying) when a
    /// track is present. Used to drive synced lyrics off Spotify's own clock.
    var onUpdate: ((String, String, TimeInterval, Bool) -> Void)?

    private var timer: Timer?
    private var lastArtURL: String?

    private static let script = """
    if application "Spotify" is not running then return ""
    tell application "Spotify" to return (name of current track) & linefeed & (artist of current track) & linefeed & (artwork url of current track) & linefeed & (player state as text) & linefeed & (player position as text)
    """

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: Self.script) else { return }
        let desc = s.executeAndReturnError(&err)
        if err != nil { return }   // Spotify not running / not yet authorized
        apply(desc.stringValue ?? "")
    }

    private func apply(_ raw: String) {
        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 3, !parts[0].isEmpty else {
            title = ""; artist = ""; artwork = nil; lastArtURL = nil; playing = false; return
        }
        title = parts[0]
        artist = parts[1]
        playing = parts.count >= 4 ? parts[3] == "playing" : true
        let position = parts.count >= 5 ? (TimeInterval(parts[4]) ?? 0) : 0
        let url = parts[2]
        if url != lastArtURL, !url.isEmpty {
            lastArtURL = url
            fetchArt(url)
        }
        onUpdate?(title, artist, position, playing)
    }

    private func fetchArt(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let img = NSImage(data: data) else { return }
            await MainActor.run { self?.artwork = img }
        }
    }
}

struct LyricLine: Identifiable {
    let id = UUID()
    let time: TimeInterval   // seconds from song start
    let text: String
}

enum LyricsProvider {

    private struct LRCResponse: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("LiveKaraoke (https://github.com/adityakinifr/livekaraoke)",
                   forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Returns timed lyric lines, or nil if none are available. Tries the exact
    /// `get` endpoint first, then falls back to `search` (which is far more
    /// forgiving) and takes the first result that actually has synced lyrics.
    static func fetch(artist: String, title: String) async -> [LyricLine]? {
        if let lines = await exactGet(artist: artist, title: title) { return lines }
        return await searchFallback(artist: artist, title: title)
    }

    private static func exactGet(artist: String, title: String) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(LRCResponse.self, from: data)
            guard let lrc = decoded.syncedLyrics, !lrc.isEmpty else { return nil }
            return parseLRC(lrc)
        } catch { return nil }
    }

    private static func searchFallback(artist: String, title: String) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let results = try JSONDecoder().decode([LRCResponse].self, from: data)
            // First result that has non-empty synced lyrics.
            for r in results {
                if let lrc = r.syncedLyrics, !lrc.isEmpty { return parseLRC(lrc) }
            }
            return nil
        } catch { return nil }
    }

    /// Parses standard LRC: lines like "[01:23.45] some text" (multiple stamps ok).
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let stamp = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+)(?:\\.(\\d+))?\\]")

        for raw in lrc.split(whereSeparator: \.isNewline) {
            let s = String(raw)
            let ns = s as NSString
            let matches = stamp.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            // Text is whatever follows the final timestamp on the line.
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let text = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)

            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac: Double = 0
                let fracRange = m.range(at: 3)
                if fracRange.location != NSNotFound {
                    let fs = ns.substring(with: fracRange)
                    frac = (Double(fs) ?? 0) / pow(10, Double(fs.count))
                }
                let t = mm * 60 + ss + frac
                if !text.isEmpty { lines.append(LyricLine(time: t, text: text)) }
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
