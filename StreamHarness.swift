// StreamHarness coordinates command-line playback. It uses AudioStream for the custom
// decoder path, AVPlayer for HLS or forced AVPlayer playback, and prints state,
// metadata, and optional power-level output for main.swift.
import AVFoundation
import Dispatch
import Darwin
import Foundation

@MainActor
final class StreamHarness: NSObject, AudioStreamDelegate, @preconcurrency AVPlayerItemMetadataOutputPushDelegate {
    private static let preferredMetadataKeys = [
        "StreamTitle",
        "StreamUrl",
        "IcecastStationName",
        "icy-name",
        "icy-genre",
        "icy-url"
    ]

    private let audioStream: AudioStream
    private var hlsPlayer: AVPlayer?
    private var hlsPlayerItemObservation: NSKeyValueObservation?
    private var hlsPlayerFailureObserver: NSObjectProtocol?
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

    func run(
        urls: [URL],
        playDuration: TimeInterval = 5,
        printPowerLevels: Bool = false,
        forceAVPlayer: Bool = false
    ) async -> Int32 {
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
                        if forceAVPlayer || Self.isHLSURL(url) {
                            try await self.playAVPlayer(
                                url: url,
                                playDuration: playDuration,
                                printPowerLevels: printPowerLevels,
                                isHLS: Self.isHLSURL(url)
                            )
                        } else {
                            try await self.playStream(url: url, playDuration: playDuration, printPowerLevels: printPowerLevels)
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

        let orderedKeys = Self.preferredMetadataKeys + metadata.keys.sorted().filter { !Self.preferredMetadataKeys.contains($0) }
        for key in orderedKeys {
            printMetadataValue(metadata[key], forKey: key)
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
                    try await Task.sleep(nanoseconds: 100_000_000)
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

    private func playStream(url: URL, playDuration: TimeInterval, printPowerLevels: Bool) async throws {
        audioStream.setURL(url)
        await audioStream.open()
        if printPowerLevels {
            startPowerLevelLogging()
        }

        do {
            try await sleep(for: playDuration)
        } catch {
            stopPowerLevelLogging()
            await audioStream.close()
            throw error
        }

        stopPowerLevelLogging()
        await audioStream.close()
    }

    private func playAVPlayer(url: URL, playDuration: TimeInterval, printPowerLevels: Bool, isHLS: Bool) async throws {

		print("Using AVPlayer")

        if isHLS {
            print("HLS Stream")
        }
        stopHLSPlayback()

        if printPowerLevels {
            print("power metering unavailable for AVPlayer playback")
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
            try await sleep(for: playDuration)
        } catch {
            stopHLSPlayback()
            throw error
        }

        stopHLSPlayback()
    }

    private func installHLSFailureObserver(for playerItem: AVPlayerItem) {
        hlsPlayerFailureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
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
    }

    private func stopHLSPlayback() {
        hlsPlayerItemObservation?.invalidate()
        hlsPlayerItemObservation = nil

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

    private func printMetadataValue(_ value: String?, forKey key: String) {
        guard let value, !value.isEmpty, lastPrintedMetadata[key] != value else {
            return
        }

        print("\(key): \(value)")
        lastPrintedMetadata[key] = value
    }

    private func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
