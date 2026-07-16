// HarnessSupport contains command-line support code shared by main.swift and
// StreamHarness setup. It validates input URLs, expands local files, and resolves
// PLS/M3U playlists into playable stream URLs.
import Foundation

enum HarnessInputError: LocalizedError {
    case invalidInput(String)
    case invalidVolume(String)
    case invalidPlayDuration(String)
    case emptyPlaylist(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(value):
            return "invalid input: \(value)"
        case let .invalidVolume(value):
            return "invalid --volume value: \(value) (expected 0.0 to 1.0)"
        case let .invalidPlayDuration(value):
            return "invalid --play-duration value: \(value) (expected seconds >= 0)"
        case let .emptyPlaylist(url):
            return "no stream URLs found in playlist: \(url.absoluteString)"
        }
    }
}

enum HarnessSupport {
    static func resolvePlayableURLs(from arguments: [String]) async throws -> [URL] {
        var resolved: [URL] = []

        for argument in arguments {
            guard let url = resolveInputURL(argument) else {
                throw HarnessInputError.invalidInput(argument)
            }

            resolved.append(try await firstPlayableURL(for: url))
        }

        return resolved
    }

    private static func resolveInputURL(_ argument: String) -> URL? {
        if let url = URL(string: argument), url.scheme != nil {
            return url
        }

        let expandedPath = (argument as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath) {
            return URL(fileURLWithPath: expandedPath)
        }

        return nil
    }

    private static func loadPlaylistString(from url: URL) async throws -> String {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (remoteData, _) = try await URLSession.shared.data(from: url)
            data = remoteData
        }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .ascii) {
            return text
        }

        return String(decoding: data, as: UTF8.self)
    }

    private static func parsePlaylist(from url: URL, transform: (String) -> URL?) async throws -> [URL] {
        let playlist = try await loadPlaylistString(from: url)
        let resolvedURLs = playlist
            .components(separatedBy: .newlines)
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                return transform(line)
            }

        guard !resolvedURLs.isEmpty else {
            throw HarnessInputError.emptyPlaylist(url)
        }

        return resolvedURLs
    }

    private static func parsePLS(from url: URL) async throws -> [URL] {
        try await parsePlaylist(from: url) { line in
            guard line.lowercased().hasPrefix("file") else {
                return nil
            }

            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                return nil
            }

            return URL(string: parts[1])
        }
    }

    private static func parseM3U(from url: URL) async throws -> [URL] {
        try await parsePlaylist(from: url) { line in
            guard !line.isEmpty, !line.hasPrefix("#") else {
                return nil
            }

            return URL(string: line)
        }
    }

    private static func firstPlayableURL(for url: URL) async throws -> URL {
        switch url.pathExtension.lowercased() {
        case "pls":
            return try await parsePLS(from: url)[0]
        case "m3u":
            return try await parseM3U(from: url)[0]
        default:
            return url
        }
    }
}
