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

    /// Returns timed lyric lines, or nil if none are available.
    static func fetch(artist: String, title: String) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("LiveKaraoke (https://github.com/adityakinifr/livekaraoke)",
                         forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(LRCResponse.self, from: data)
            guard let lrc = decoded.syncedLyrics, !lrc.isEmpty else { return nil }
            return parseLRC(lrc)
        } catch {
            return nil
        }
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
