import AVFoundation
import Dispatch
import Darwin
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

private func resolveInputURL(_ argument: String) -> URL? {
    if let url = URL(string: argument), url.scheme != nil {
        return url
    }

    let expandedPath = (argument as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expandedPath) {
        return URL(fileURLWithPath: expandedPath)
    }

    return nil
}

private func loadPlaylistString(from url: URL) async throws -> String {
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

private func parsePLS(from url: URL) async throws -> [URL] {
    let playlist = try await loadPlaylistString(from: url)
    var resolvedURLs: [URL] = []

    for rawLine in playlist.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.lowercased().hasPrefix("file") else {
            continue
        }

        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let streamURL = URL(string: parts[1]) else {
            continue
        }

        resolvedURLs.append(streamURL)
    }

    guard !resolvedURLs.isEmpty else {
        throw HarnessInputError.emptyPlaylist(url)
    }

    return resolvedURLs
}

private func parseM3U(from url: URL) async throws -> [URL] {
    let playlist = try await loadPlaylistString(from: url)
    var resolvedURLs: [URL] = []

    for rawLine in playlist.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), let streamURL = URL(string: line) else {
            continue
        }

        resolvedURLs.append(streamURL)
    }

    guard !resolvedURLs.isEmpty else {
        throw HarnessInputError.emptyPlaylist(url)
    }

    return resolvedURLs
}

private func resolvePlayableURLs(from arguments: [String]) async throws -> [URL] {
    var resolved: [URL] = []

    for argument in arguments {
        guard let url = resolveInputURL(argument) else {
            throw HarnessInputError.invalidInput(argument)
        }

        switch url.pathExtension.lowercased() {
        case "pls":
            let playlistURLs = try await parsePLS(from: url)
            resolved.append(playlistURLs[0])
        case "m3u":
            let playlistURLs = try await parseM3U(from: url)
            resolved.append(playlistURLs[0])
        default:
            resolved.append(url)
        }
    }

    return resolved
}

@MainActor
final class StreamHarness: NSObject, AudioStreamDelegate, @preconcurrency AVPlayerItemMetadataOutputPushDelegate {
    private let audioStream: AudioStream
    private var hlsPlayer: AVPlayer?
    private var hlsPlayerItemObservation: NSKeyValueObservation?
    private var hlsPlayerFailureObserver: NSObjectProtocol?
    private var hlsMetadataOutput: AVPlayerItemMetadataOutput?
    private var volume: Float = 1.0
    private var stopSignal: DispatchSourceSignal?
    private var finishContinuation: CheckedContinuation<Int32, Never>?
    private var lastPrintedMetadata: [String: String] = [:]
    private var rotationTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?

    init(configuration: AudioStreamConfiguration = .init(), debugLoggingEnabled: Bool = false) {
        audioStream = AudioStream(
            configuration: configuration,
            sourceFactory: { _ in
                let stream = URLSessionInputStream()
                stream.debugLoggingEnabled = debugLoggingEnabled
                return stream
            },
            rendererFactory: {
                let queue = EngineAudioQueue()
                queue.debugLoggingEnabled = debugLoggingEnabled
                return queue
            }
        )
        super.init()
        audioStream.debugLoggingEnabled = debugLoggingEnabled
        audioStream.delegate = self
    }

    func run(urls: [URL], playDuration: TimeInterval = 5, printPowerLevels: Bool = false) async -> Int32 {
        guard !urls.isEmpty else {
            return 2
        }

        installSignalHandler()
        rotationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                for (index, url) in urls.enumerated() {
                    self.lastPrintedMetadata.removeAll(keepingCapacity: true)
                    print("playing [\(index + 1)/\(urls.count)]: \(url.absoluteString)")
                    do {
                        if Self.isHLSURL(url) {
                            try await self.playHLS(url: url, playDuration: playDuration, printPowerLevels: printPowerLevels)
                        } else {
                            self.audioStream.setURL(url)
                            await self.audioStream.open()
                            if printPowerLevels {
                                self.startPowerLevelLogging()
                            }

                            try await Task.sleep(nanoseconds: UInt64(playDuration * 1_000_000_000))
                            self.stopPowerLevelLogging()
                            await self.audioStream.close()
                        }
                    } catch {
                        if error is CancellationError {
                            return
                        }

                        fputs("\(error.localizedDescription)\n", stderr)
                        self.finish(with: 1)
                        return
                    }
                }
            }
        }

        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func audioStream(_ stream: AudioStream, didChangeState state: AudioStream.State) {
        print("state: \(state)")

        switch state {
        case .failed:
            finish(with: 1)
        case .playbackCompleted:
            finish(with: 0)
        default:
            break
        }
    }

    func audioStream(_ stream: AudioStream, didReceiveError error: AudioStreamFailure) {
        fputs("error [\(error.code.rawValue)]: \(error.description)\n", stderr)
        finish(with: 1)
    }

    func audioStream(_ stream: AudioStream, didReceiveMetadata metadata: [String : String]) {
        printMetadata(metadata)
    }

    private func printMetadata(_ metadata: [String: String]) {
        guard !metadata.isEmpty else {
            return
        }

        let preferredKeys = [
            "StreamTitle",
            "StreamUrl",
            "IcecastStationName",
            "icy-name",
            "icy-genre",
            "icy-url"
        ]

        for key in preferredKeys {
            guard let value = metadata[key], !value.isEmpty else {
                continue
            }

            if lastPrintedMetadata[key] != value {
                print("\(key): \(value)")
                lastPrintedMetadata[key] = value
            }
        }

        for key in metadata.keys.sorted() where !preferredKeys.contains(key) {
            guard let value = metadata[key], !value.isEmpty else {
                continue
            }

            if lastPrintedMetadata[key] != value {
                print("\(key): \(value)")
                lastPrintedMetadata[key] = value
            }
        }
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.shutdown(exitCode: 130)
            }
        }
        signalSource.resume()
        stopSignal = signalSource
    }

    private func shutdown(exitCode: Int32) async {
        rotationTask?.cancel()
        rotationTask = nil
        stopPowerLevelLogging()
        stopHLSPlayback()
        await audioStream.close()
        finish(with: exitCode)
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        audioStream.setVolume(volume)
    }

    private func finish(with exitCode: Int32) {
        stopPowerLevelLogging()
        stopHLSPlayback()
        stopSignal?.cancel()
        stopSignal = nil

        guard let finishContinuation else {
            return
        }

        self.finishContinuation = nil
        finishContinuation.resume(returning: exitCode)
    }

    private func startPowerLevelLogging() {
        stopPowerLevelLogging()
        powerTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                let levels = self.audioStream.levels
                print(
                    String(
                        format: "power avg=%0.1f dB peak=%0.1f dB",
                        levels.averagePower,
                        levels.peakPower
                    )
                )

                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopPowerLevelLogging() {
        powerTask?.cancel()
        powerTask = nil
    }

    private func playHLS(url: URL, playDuration: TimeInterval, printPowerLevels: Bool) async throws {
        stopHLSPlayback()

        if printPowerLevels {
            print("power metering unavailable for HLS playback")
        }

        let playerItem = AVPlayerItem(url: url)
        installHLSMetadataOutput(for: playerItem)
        let player = AVPlayer(playerItem: playerItem)
        player.volume = volume
        hlsPlayer = player
        installHLSFailureObserver(for: playerItem)

        try await waitUntilReadyToPlay(playerItem)
        await printHLSStaticMetadata(for: playerItem)
        print("state: playing")
        player.play()

        do {
            try await Task.sleep(nanoseconds: UInt64(playDuration * 1_000_000_000))
        } catch {
            stopHLSPlayback()
            throw error
        }

        stopHLSPlayback()
    }

    private func installHLSFailureObserver(for playerItem: AVPlayerItem) {
        hlsPlayerFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            fputs("\((error?.localizedDescription ?? "HLS playback failed"))\n", stderr)
            Task { @MainActor [weak self] in
                self?.finish(with: 1)
            }
        }
    }

    private func installHLSMetadataOutput(for playerItem: AVPlayerItem) {
        let metadataOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metadataOutput.setDelegate(self, queue: .main)
        playerItem.add(metadataOutput)
        hlsMetadataOutput = metadataOutput
    }

    private func stopHLSPlayback() {
        hlsPlayerItemObservation?.invalidate()
        hlsPlayerItemObservation = nil
        hlsMetadataOutput = nil

        if let hlsPlayerFailureObserver {
            NotificationCenter.default.removeObserver(hlsPlayerFailureObserver)
            self.hlsPlayerFailureObserver = nil
        }

        hlsPlayer?.pause()
        hlsPlayer?.replaceCurrentItem(with: nil)
        hlsPlayer = nil
    }

    private func waitUntilReadyToPlay(_ playerItem: AVPlayerItem) async throws {
        switch playerItem.status {
        case .readyToPlay:
            return
        case .failed:
            throw playerItem.error ?? AudioStreamFailure(code: .open, description: "Failed to prepare HLS playback")
        case .unknown:
            break
        @unknown default:
            break
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            observation = playerItem.observe(\.status, options: [.initial, .new]) { item, _ in
                switch item.status {
                case .readyToPlay:
                    observation?.invalidate()
                    continuation.resume()
                case .failed:
                    observation?.invalidate()
                    continuation.resume(throwing: item.error ?? AudioStreamFailure(code: .open, description: "Failed to prepare HLS playback"))
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
            self.hlsPlayerItemObservation = observation
        }
    }

    private func printHLSStaticMetadata(for playerItem: AVPlayerItem) async {
        do {
            let assetMetadata = try await playerItem.asset.load(.commonMetadata)
            let metadata = await Self.dictionary(from: assetMetadata)
            printMetadata(metadata)
        } catch {
            // Ignore metadata load failures and continue playback.
        }
    }

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from playerItemTrack: AVPlayerItemTrack?
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for group in groups {
                let metadata = await Self.dictionary(from: group.items)
                self.printMetadata(metadata)
            }
        }
    }

    private static func isHLSURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
    }

    nonisolated private static func dictionary(from items: [AVMetadataItem]) async -> [String: String] {
        var metadata: [String: String] = [:]

        for item in items {
            guard let value = await stringValue(from: item), !value.isEmpty else {
                continue
            }

            let key = metadataKey(for: item)
            metadata[key] = value
        }

        return metadata
    }

    nonisolated private static func metadataKey(for item: AVMetadataItem) -> String {
        if let commonKey = item.commonKey?.rawValue, !commonKey.isEmpty {
            return commonKey
        }

        if let identifier = item.identifier?.rawValue, !identifier.isEmpty {
            return identifier
        }

        if let key = item.key as? String, !key.isEmpty {
            return key
        }

        return "metadata"
    }

    nonisolated private static func stringValue(from item: AVMetadataItem) async -> String? {
        if let stringValue = try? await item.load(.stringValue) {
            return stringValue
        }

        if let numberValue = try? await item.load(.numberValue) {
            return numberValue.stringValue
        }

        if let dateValue = try? await item.load(.dateValue) {
            return ISO8601DateFormatter().string(from: dateValue)
        }

        return nil
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
var debugLoggingEnabled = false
var volume: Float = 1.0
var playDuration: TimeInterval = 5
var printPowerLevels = false
var positionalArguments: [String] = []

var argumentIndex = 0
while argumentIndex < arguments.count {
    let argument = arguments[argumentIndex]
    switch argument {
    case "--debug":
        debugLoggingEnabled = true
        argumentIndex += 1
    case "--power":
        printPowerLevels = true
        argumentIndex += 1
    case "--volume":
        let valueIndex = argumentIndex + 1
        guard valueIndex < arguments.count else {
            fputs("missing value for --volume\n", stderr)
            Darwin.exit(2)
        }
        guard let parsedVolume = Float(arguments[valueIndex]), parsedVolume >= 0, parsedVolume <= 1 else {
            fputs("\(HarnessInputError.invalidVolume(arguments[valueIndex]).localizedDescription)\n", stderr)
            Darwin.exit(2)
        }
        volume = parsedVolume
        argumentIndex += 2
    case "--play-duration":
        let valueIndex = argumentIndex + 1
        guard valueIndex < arguments.count else {
            fputs("missing value for --play-duration\n", stderr)
            Darwin.exit(2)
        }
        guard let parsedPlayDuration = TimeInterval(arguments[valueIndex]), parsedPlayDuration >= 0 else {
            fputs("\(HarnessInputError.invalidPlayDuration(arguments[valueIndex]).localizedDescription)\n", stderr)
            Darwin.exit(2)
        }
        playDuration = parsedPlayDuration
        argumentIndex += 2
    default:
        positionalArguments.append(argument)
        argumentIndex += 1
    }
}

guard !positionalArguments.isEmpty else {
    fputs("usage: swift-audio-streamer [--debug] [--power] [--volume 0.0-1.0] [--play-duration seconds] <stream-url> [stream-url ...]\n", stderr)
    Darwin.exit(2)
}

var urls: [URL] = []

Task { @MainActor in
    if debugLoggingEnabled {
        fputs("[main] starting swift-audio-streamer\n", stderr)
    }

    do {
        urls = try await resolvePlayableURLs(from: positionalArguments)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        Darwin.exit(2)
    }

    let harness = StreamHarness(debugLoggingEnabled: debugLoggingEnabled)
    harness.setVolume(volume)
    let exitCode = await harness.run(urls: urls, playDuration: playDuration, printPowerLevels: printPowerLevels)
    if debugLoggingEnabled {
        fputs("[main] exiting with code \(exitCode)\n", stderr)
    }
    Darwin.exit(exitCode)
}

dispatchMain()
