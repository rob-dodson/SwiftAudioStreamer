import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

@MainActor
public final class AudioStream {
    public enum State: Sendable {
        case stopped
        case buffering
        case playing
        case paused
        case seeking
        case failed
        case endOfFile
        case playbackCompleted
    }

    public weak var delegate: AudioStreamDelegate?
    public var debugLoggingEnabled = false

    public private(set) var state: State = .stopped
    public private(set) var sourceURL: URL?
    public private(set) var outputFileURL: URL?
    public private(set) var contentType: String?
    public private(set) var sourceFormat: AVAudioFormat?

    public var strictContentTypeChecking: Bool
    public var defaultContentType = "audio/mpeg"

    private let configuration: AudioStreamConfiguration
    private let sourceFactory: (URL) -> AudioStreamSource?
    private let rendererFactory: () -> AudioStreamRenderer?

    private var source: AudioStreamSource?
    private var renderer: AudioStreamRenderer?

    private var inputStreamRunning = false
    private var parserRunning = false
    private var initialBufferingCompleted = false
    private var preloading = false
    private var audioQueueConsumedPackets = false
    private var discontinuity = false
    private var decoderShouldRun = false

    private var defaultContentLength: Int64 = 0
    private var contentLengthStorage: Int64 = 0
    private var originalContentLength: Int64 = 0
    private var bytesReceived: Int64 = 0
    private var dataOffset: Int64 = 0
    private var seekOffset: Float = 0
    private var metadataByteSize: Int64 = 0

    private var packetIdentifier: UInt64 = 0
    private var playingPacketIdentifier: UInt64 = 0
    private var queuedPackets: [QueuedPacket] = []
    private var processedPackets: [QueuedPacket] = []
    private var cachedDataByteCount = 0
    private var packetsToRewind = 0

    private var audioDataByteCountStorage: Int64 = 0
    private var audioDataPacketCount: Int64 = 0
    private var packetDuration: Double = 0
    private var bitRate: UInt32 = 0
    private var bitrateSamples: [Double] = []

    private var outputVolume: Float = 1.0
    private var bounceCount = 0
    private var firstBufferingDate: Date?

    private var watchdogTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var audioFileStream: AudioFileStreamID?
    private var audioConverter: AudioConverterRef?
    private var outputAudioFormat: AVAudioFormat?
    private var outputBufferSize: UInt32 = 32_768
    private var playPacketIndex = 0
    private var converterRunOutOfData = false
    private var decoderFailed = false
    private let currentInputPacketDescriptionPointer = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private var decodeAttemptCount = 0
    private var converterInputCount = 0

    public init(
        configuration: AudioStreamConfiguration = .init(),
        sourceFactory: @escaping (URL) -> AudioStreamSource? = { _ in nil },
        rendererFactory: @escaping () -> AudioStreamRenderer? = { nil }
    ) {
        self.configuration = configuration
        self.sourceFactory = sourceFactory
        self.rendererFactory = rendererFactory
        self.strictContentTypeChecking = configuration.requireStrictContentTypeChecking
    }

    deinit {
        watchdogTask?.cancel()
        decodeTask?.cancel()
        currentInputPacketDescriptionPointer.deallocate()
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else {
            return
        }

        fputs("[AudioStream] \(message)\n", stderr)
    }

    public func open() async {
        await open(at: nil)
    }

    public func open(at position: InputStreamPosition?) async {
        guard !inputStreamRunning, !parserRunning else {
            debugLog("open ignored because stream is already active")
            return
        }

        resetForOpen(position: position)
        debugLog("opening url=\(sourceURL?.absoluteString ?? "<nil>") position.start=\(position?.start ?? 0) position.end=\(position?.end.map(String.init) ?? "nil")")

        guard let source else {
            closeAndSignalError(
                .open,
                description: "No input source is configured for \(sourceURL?.absoluteString ?? "this stream")"
            )
            return
        }

        do {
            try await source.open(at: position)
            inputStreamRunning = true
            setState(.buffering)
            debugLog("source opened successfully")

            if !preloading, configuration.startupWatchdogPeriod > 0 {
                createWatchdogTimer()
            }
        } catch {
            debugLog("source open failed: \(error.localizedDescription)")
            closeAndSignalError(.open, description: error.localizedDescription)
        }
    }

    public func close(closeParser: Bool = true) async {
        debugLog("closing stream closeParser=\(closeParser)")
        invalidateWatchdogTimer()
        decodeTask?.cancel()
        decodeTask = nil

        if inputStreamRunning {
            await source?.close()
            inputStreamRunning = false
        }

        if closeParser {
            parserRunning = false
            if let audioFileStream {
                AudioFileStreamClose(audioFileStream)
                self.audioFileStream = nil
            }
        }

        if let audioConverter {
            AudioConverterDispose(audioConverter)
            self.audioConverter = nil
            debugLog("audio converter disposed")
        }

        setDecoderRunState(false)
        closeRenderer()
        clearPacketCache()

        if state != .failed, state != .seeking {
            setState(.stopped)
        }
    }

    public func pause() {
        debugLog("toggling pause")
        renderer?.pause()
        setState(.paused)
    }

    public func rewind(_ seconds: TimeInterval) {
        guard contentLength <= 0 else {
            return
        }

        let packetCount = cachedDataCount
        guard packetCount > 0 else {
            return
        }

        let averagePacketSize = Double(cachedDataSize) / Double(packetCount)
        let bufferSizeForSecond = bitrate / 8.0
        let totalAudioRequiredInBytes = seconds * bufferSizeForSecond
        let packets = Int(totalAudioRequiredInBytes / averagePacketSize)

        if packetCount - packets >= 16 {
            packetsToRewind = packets
        }
    }

    public func startCachedDataPlayback() async {
        preloading = false

        if !inputStreamRunning {
            await open()
        } else {
            determineBufferingLimits()
        }
    }

    public func playbackPosition() -> PlaybackPosition {
        guard parserRunning else {
            return .init()
        }

        let timePlayed = (durationInSeconds * Double(seekOffset)) + (renderer?.currentTimeSeconds ?? 0)
        let duration = durationInSeconds
        let offset = duration > 0 ? Float(timePlayed / duration) : 0
        return PlaybackPosition(offset: offset, timePlayed: timePlayed)
    }

    public var audioDataByteCount: Int64 {
        if audioDataByteCountStorage > 0 {
            return audioDataByteCountStorage
        }

        return max(0, contentLength - metadataByteSize)
    }

    public var durationInSeconds: TimeInterval {
        if
            let sourceFormat,
            audioDataPacketCount > 0,
            sourceFormat.streamDescription.pointee.mFramesPerPacket > 0
        {
            let framesPerPacket = Double(sourceFormat.streamDescription.pointee.mFramesPerPacket)
            return Double(audioDataPacketCount) * framesPerPacket / sourceFormat.sampleRate
        }

        let bytes = audioDataByteCount
        let rate = bitrate
        guard bytes > 0, rate > 0 else {
            return 0
        }

        return Double(bytes) / (rate * 0.125)
    }

    public func seekToOffset(_ offset: Float) async {
        guard state == .playing || state == .endOfFile else {
            debugLog("seek ignored because state=\(state)")
            return
        }

        setState(.seeking)
        originalContentLength = contentLength
        setDecoderRunState(false)
        packetsToRewind = 0

        seekOffset = max(0, min(offset, 1))
        closeRenderer()

        let position = streamPosition(for: seekOffset)
        guard position.start > 0 || position.end != nil else {
            closeAndSignalError(.network, description: "Failed to retrieve seeking position")
            return
        }

        do {
            try await source?.open(at: position)
            contentLengthStorage = originalContentLength
            setState(.buffering)
            inputStreamRunning = true
            debugLog("seek reopened source at byte \(position.start)")
        } catch {
            debugLog("seek reopen failed: \(error.localizedDescription)")
            closeAndSignalError(.open, description: error.localizedDescription)
        }
    }

    public func streamPosition(for offset: Float) -> InputStreamPosition {
        let duration = durationInSeconds
        guard duration > 0 else {
            return .init()
        }

        let clampedOffset = max(0, min(offset, 1))
        let start = dataOffset + Int64(Double(contentLength - dataOffset) * Double(clampedOffset))
        return InputStreamPosition(start: start, end: contentLength)
    }

    public var currentVolume: Float { outputVolume }

    public func setVolume(_ volume: Float) {
        let clamped = max(0, min(volume, 1))
        outputVolume = clamped
        renderer?.volume = clamped
    }

    public func setPlayRate(_ playRate: Float) {
        renderer?.rate = playRate
    }

    public func setURL(_ url: URL) {
        sourceURL = url
        source = sourceFactory(url)
        source?.url = url
        source?.delegate = self
    }

    public func setDefaultContentLength(_ length: Int64) {
        defaultContentLength = length
    }

    public func setContentLength(_ length: Int64) {
        contentLengthStorage = length
    }

    public func setPreloading(_ enabled: Bool) {
        preloading = enabled
    }

    public var isPreloading: Bool { preloading }

    public func setOutputFile(_ url: URL?) {
        outputFileURL = url
    }

    public func sourceFormatDescription() -> String? {
        guard let sourceFormat else {
            return nil
        }

        let formatID = sourceFormat.streamDescription.pointee.mFormatID.bigEndian
        let bytes = withUnsafeBytes(of: formatID) { rawBuffer in
            Array(rawBuffer.prefix(4))
        }
        let formatCode = String(bytes: bytes, encoding: .ascii) ?? "\(sourceFormat.commonFormat.rawValue)"
        return "formatID: \(formatCode), sample rate: \(sourceFormat.sampleRate)"
    }

    public func createCacheIdentifier(for url: URL) -> String {
        let digest = Insecure.SHA1.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "FSCache-\(hex)"
    }

    public var cachedDataSize: Int { cachedDataByteCount }

    public var bitrate: Double {
        if bitRate > 0 {
            return Double(bitRate)
        }

        guard bitrateSamples.count >= 50 else {
            return 0
        }

        return bitrateSamples.reduce(0, +) / Double(bitrateSamples.count)
    }

    public var contentLength: Int64 {
        if contentLengthStorage == 0 {
            contentLengthStorage = source?.contentLength ?? defaultContentLength
        }

        return contentLengthStorage
    }

    public var playbackDataCount: Int { max(queuedPackets.count - playPacketIndex - packetsToRewind, 0) }

    public var levels: AudioLevelMeterState { renderer?.levels ?? .init() }

    public func rendererStateChanged(_ rendererState: AudioRendererState) {
        debugLog("renderer state changed -> \(rendererState)")
        switch rendererState {
        case .running where state != .seeking:
            invalidateWatchdogTimer()
            setState(.playing)
            if renderer?.volume != outputVolume {
                renderer?.volume = outputVolume
            }
        case .idle:
            setState(.stopped)
        case .paused:
            setState(.paused)
        default:
            break
        }
    }

    public func rendererBuffersEmpty() async {
        let count = playbackDataCount
        debugLog("renderer buffers empty queued=\(queuedPackets.count) playbackCount=\(count) bytesReceived=\(bytesReceived)")

        if count == 0, inputStreamRunning, state != .failed {
            setState(.buffering)
            noteBufferingBounce()
            createWatchdogTimer()
            await source?.setReceivingEnabled(true)
            return
        }

        if count > 0 {
            determineBufferingLimits()
        } else {
            setState(.playbackCompleted)
            await close()
        }
    }

    public func rendererInitializationFailed(_ error: Error) {
        debugLog("renderer initialization failed: \(error.localizedDescription)")
        closeAndSignalError(.streamParse, description: error.localizedDescription)
    }

    public func rendererFinishedPlayingPacket() {}

    public func sourceDidBecomeReady() {
        guard !parserRunning else {
            debugLog("source ready ignored because parser already running")
            return
        }

        let reportedContentType = source?.contentType
        contentType = reportedContentType
        debugLog("source ready contentType=\(reportedContentType ?? "<nil>") contentLength=\(source?.contentLength.map(String.init) ?? "nil")")

        if strictContentTypeChecking, !isSupportedAudioContentType(reportedContentType) {
            let description: String
            if let reportedContentType {
                description = "Strict content type checking active, \(reportedContentType) is not an audio content type"
            } else {
                description = "Strict content type checking active, no content type provided by the server"
            }

            closeAndSignalError(.open, description: description)
            return
        }

        audioDataByteCountStorage = 0
        let fileType = audioStreamType(from: reportedContentType ?? defaultContentType)
        let status = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            audioFileStreamPropertyCallback,
            audioFileStreamPacketsCallback,
            fileType,
            &audioFileStream
        )

        guard status == noErr else {
            debugLog("AudioFileStreamOpen failed status=\(status)")
            closeAndSignalError(.open, description: "Audio file stream parser open error (\(status))")
            return
        }

        parserRunning = true
        debugLog("audio file stream parser opened")
    }

    public func sourceDidReceive(bytes: Data) {
        guard inputStreamRunning else {
            debugLog("dropping \(bytes.count) bytes because input stream is not running")
            return
        }

        if cachedDataByteCount >= configuration.maxPrebufferedByteCount {
            debugLog("prebuffer limit hit cachedDataByteCount=\(cachedDataByteCount), pausing source delivery")
            Task { [weak self] in
                await self?.source?.setReceivingEnabled(false)
            }
            return
        }

        bytesReceived += Int64(bytes.count)
        debugLog("received \(bytes.count) bytes total=\(bytesReceived)")
        if parserRunning, let audioFileStream {
            let parseFlags: AudioFileStreamParseFlags = discontinuity ? .discontinuity : []
            let status = bytes.withUnsafeBytes { rawBuffer in
                AudioFileStreamParseBytes(
                    audioFileStream,
                    UInt32(bytes.count),
                    rawBuffer.baseAddress,
                    parseFlags
                )
            }

            if status != noErr {
                debugLog("AudioFileStreamParseBytes failed status=\(status)")
                closeAndSignalError(.streamParse, description: "Audio file stream parse bytes error (\(status))")
                return
            }

            discontinuity = false
        }
    }

    public func sourceDidEnd() {
        guard inputStreamRunning else {
            debugLog("source end ignored because input stream is not running")
            return
        }
        debugLog("source ended contentLength=\(contentLength)")

        guard contentLength > 0 else {
            closeAndSignalError(.network, description: "Stream ended abruptly")
            return
        }

        setState(.endOfFile)
        inputStreamRunning = false
    }

    public func sourceDidFail(_ error: Error) {
        guard inputStreamRunning else {
            debugLog("source failure ignored because input stream is not running: \(error.localizedDescription)")
            return
        }

        debugLog("source failed: \(error.localizedDescription)")
        closeAndSignalError(.network, description: error.localizedDescription)
    }

    public func sourceDidReceive(metadata: [String: String]) {
        debugLog("metadata keys=\(metadata.keys.sorted())")
        delegate?.audioStream(self, didReceiveMetadata: metadata)
    }

    public func sourceDidReceive(metadataByteSize: Int64) {
        self.metadataByteSize = metadataByteSize
        debugLog("metadata byte size=\(metadataByteSize)")
    }

    public func setSourceFormat(_ format: AVAudioFormat) {
        sourceFormat = format
        packetDuration = packetDuration(
            for: format.streamDescription.pointee.mFramesPerPacket,
            sampleRate: format.sampleRate
        )
        debugLog("source format sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
    }

    public func setAudioData(byteCount: Int64, packetCount: Int64) {
        audioDataByteCountStorage = byteCount
        audioDataPacketCount = packetCount
    }

    public func reportBitrate(_ bitrate: UInt32) {
        let hadBitrate = self.bitrate > 0
        bitRate = bitrate
        debugLog("bitrate reported=\(bitrate)")
        if !hadBitrate, bitrate > 0 {
            delegate?.audioStreamBitrateBecameAvailable(self)
        }
    }

    public func appendEstimatedBitrate(_ bitrate: Double) {
        let maxSamples = 50
        bitrateSamples.append(bitrate)
        if bitrateSamples.count > maxSamples {
            bitrateSamples.removeFirst(bitrateSamples.count - maxSamples)
        }

        if bitrateSamples.count == maxSamples {
            debugLog("estimated bitrate ready=\(self.bitrate)")
            delegate?.audioStreamBitrateBecameAvailable(self)
        }
    }

    public func enqueueDecodedSamples(_ buffer: AVAudioPCMBuffer, packetCount: AVAudioPacketCount) {
        audioQueueConsumedPackets = true
        debugLog("enqueue decoded samples frames=\(buffer.frameLength) packetCount=\(packetCount)")
        renderer?.enqueue(buffer, completion: nil)
        renderer?.start()
        delegate?.audioStream(self, didProduceSamples: buffer, packetCount: packetCount)
    }

    public func setDecoderRunState(_ shouldRun: Bool) {
        decoderShouldRun = shouldRun
        if shouldRun {
            startDecodeLoopIfNeeded()
            return
        }

        decodeTask?.cancel()
        decodeTask = nil
    }

    private func resetForOpen(position: InputStreamPosition?) {
        contentLengthStorage = 0
        bytesReceived = 0
        seekOffset = 0
        bounceCount = 0
        firstBufferingDate = nil
        bitrateSamples.removeAll(keepingCapacity: true)
        audioDataPacketCount = 0
        bitRate = 0
        metadataByteSize = 0
        discontinuity = true
        audioQueueConsumedPackets = false
        packetsToRewind = 0
        playPacketIndex = 0
        converterRunOutOfData = false
        decoderFailed = false
        decodeAttemptCount = 0
        converterInputCount = 0

        invalidateWatchdogTimer()

        if position == nil {
            packetIdentifier = 0
        }

        initialBufferingCompleted = false
    }

    private func closeRenderer() {
        renderer?.stop(immediately: true)
        renderer = nil
        audioQueueConsumedPackets = false
    }

    private func closeAndSignalError(_ code: AudioStreamErrorCode, description: String) {
        debugLog("error code=\(code.rawValue) description=\(description)")
        setState(.failed)
        Task { [weak self] in
            await self?.close()
        }
        delegate?.audioStream(self, didReceiveError: .init(code: code, description: description))
    }

    private func setState(_ newState: State) {
        guard state != newState else {
            return
        }

        debugLog("state \(state) -> \(newState)")
        state = newState
        delegate?.audioStream(self, didChangeState: newState)
    }

    private func createWatchdogTimer() {
        invalidateWatchdogTimer()
        debugLog("starting watchdog period=\(configuration.startupWatchdogPeriod)")

        watchdogTask = Task { [weak self] in
            guard let self else {
                return
            }

            let duration = UInt64(configuration.startupWatchdogPeriod * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)

            guard !Task.isCancelled else {
                return
            }

            if !audioQueueConsumedPackets {
                closeAndSignalError(
                    .open,
                    description: "The stream startup watchdog activated: stream did not start to play in \(Int(configuration.startupWatchdogPeriod)) seconds"
                )
            }
        }
    }

    private func invalidateWatchdogTimer() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private var cachedDataCount: Int { queuedPackets.count }

    private func determineBufferingLimits() {
        guard !preloading else {
            return
        }

        let minimumBytes =
            contentLength > 0
            ? configuration.requiredInitialPrebufferedByteCountForNonContinuousStream
            : configuration.requiredInitialPrebufferedByteCountForContinuousStream

        let hasEnoughData = cachedDataByteCount >= minimumBytes || queuedPackets.count >= configuration.requiredInitialPrebufferedPacketCount
        debugLog("buffer check cachedBytes=\(cachedDataByteCount) queuedPackets=\(queuedPackets.count) minBytes=\(minimumBytes) minPackets=\(configuration.requiredInitialPrebufferedPacketCount) hasEnough=\(hasEnoughData)")
        guard hasEnoughData else {
            return
        }

        if renderer == nil {
            renderer = rendererFactory()
            renderer?.delegate = self
            if let renderer, let outputFormat = outputAudioFormat {
                do {
                    try renderer.prepare(outputFormat: outputFormat)
                    renderer.volume = outputVolume
                    debugLog("renderer prepared sampleRate=\(outputFormat.sampleRate) channels=\(outputFormat.channelCount)")
                } catch {
                    rendererInitializationFailed(error)
                    return
                }
            }
        }

        initialBufferingCompleted = true
        setDecoderRunState(true)
        renderer?.start()
        setState(.playing)
        invalidateWatchdogTimer()
    }

    private func clearPacketCache() {
        queuedPackets.removeAll(keepingCapacity: false)
        processedPackets.removeAll(keepingCapacity: false)
        cachedDataByteCount = 0
        packetsToRewind = 0
        playPacketIndex = 0
    }

    private func noteBufferingBounce() {
        let now = Date()

        if let firstBufferingDate {
            if now.timeIntervalSince(firstBufferingDate) >= configuration.bounceInterval {
                bounceCount = 0
                self.firstBufferingDate = nil
            } else {
                bounceCount += 1
            }
        } else {
            firstBufferingDate = now
            bounceCount += 1
        }

        if bounceCount >= configuration.maxBounceCount {
            closeAndSignalError(
                .bouncing,
                description: "Buffered \(bounceCount) times in the last \(Int(configuration.bounceInterval)) seconds"
            )
        }
    }

    private func isSupportedAudioContentType(_ contentType: String?) -> Bool {
        guard let contentType = contentType?.lowercased() else {
            return false
        }

        return ["audio/", "video/"].contains { contentType.hasPrefix($0) }
    }

    private func audioStreamType(from contentType: String?) -> AudioFileTypeID {
        switch contentType?.lowercased() {
        case "audio/mpeg":
            return kAudioFileMP3Type
        case "audio/x-wav":
            return kAudioFileWAVEType
        case "audio/x-aifc":
            return kAudioFileAIFCType
        case "audio/x-aiff":
            return kAudioFileAIFFType
        case "audio/x-m4a":
            return kAudioFileM4AType
        case "audio/mp4", "video/mp4":
            return kAudioFileMPEG4Type
        case "audio/x-caf":
            return kAudioFileCAFType
        case "audio/aac", "audio/aacp":
            return kAudioFileAAC_ADTSType
        default:
            return kAudioFileMP3Type
        }
    }

    fileprivate func configureConverter(with asbd: AudioStreamBasicDescription) throws {
        var sourceASBD = asbd
        sourceFormat = AVAudioFormat(streamDescription: &sourceASBD)
        packetDuration = packetDuration(for: asbd.mFramesPerPacket, sampleRate: asbd.mSampleRate)
        debugLog("configuring converter formatID=\(asbd.mFormatID) sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) framesPerPacket=\(asbd.mFramesPerPacket)")

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: configuration.outputSampleRate,
            channels: configuration.outputChannelCount,
            interleaved: true
        )

        guard let outputFormat else {
            throw AudioStreamFailure(code: .open, description: "Failed to create output PCM format")
        }

        self.outputAudioFormat = outputFormat

        if let audioConverter {
            AudioConverterDispose(audioConverter)
            self.audioConverter = nil
        }

        var srcASBD = asbd
        var dstASBD = outputFormat.streamDescription.pointee
        let status = AudioConverterNew(&srcASBD, &dstASBD, &audioConverter)
        guard status == noErr else {
            debugLog("AudioConverterNew failed status=\(status)")
            throw AudioStreamFailure(code: .unsupportedFormat, description: "Error creating audio converter (\(status))")
        }
        debugLog("audio converter created")

        try applyMagicCookieIfNeeded()
        debugLog("renderer preparation deferred until buffering threshold is met")
    }

    private func applyMagicCookieIfNeeded() throws {
        guard let audioFileStream, let audioConverter else {
            return
        }

        var cookieSize: UInt32 = 0
        var writable = DarwinBoolean(false)
        let infoStatus = AudioFileStreamGetPropertyInfo(
            audioFileStream,
            kAudioFileStreamProperty_MagicCookieData,
            &cookieSize,
            &writable
        )

        guard infoStatus == noErr, cookieSize > 0 else {
            return
        }

        let cookie = UnsafeMutableRawPointer.allocate(byteCount: Int(cookieSize), alignment: MemoryLayout<UInt8>.alignment)
        defer { cookie.deallocate() }

        var mutableCookieSize = cookieSize
        let propertyStatus = AudioFileStreamGetProperty(
            audioFileStream,
            kAudioFileStreamProperty_MagicCookieData,
            &mutableCookieSize,
            cookie
        )

        guard propertyStatus == noErr else {
            return
        }

        let converterStatus = AudioConverterSetProperty(
            audioConverter,
            kAudioConverterDecompressionMagicCookie,
            mutableCookieSize,
            cookie
        )

        guard converterStatus == noErr else {
            throw AudioStreamFailure(code: .open, description: "Failed to apply stream magic cookie (\(converterStatus))")
        }
    }

    private func startDecodeLoopIfNeeded() {
        guard decodeTask == nil else {
            return
        }

        debugLog("starting decode loop")
        decodeTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let decoded = await MainActor.run {
                    self.decodeSinglePacketIfNeeded()
                }

                if decoded {
                    await Task.yield()
                } else {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
        }
    }

    private func decodeSinglePacketIfNeeded() -> Bool {
        guard decoderShouldRunInternal else {
            return false
        }

        if let renderer, !renderer.isReadyForMoreData {
            if decodeAttemptCount <= 10 || decodeAttemptCount % 50 == 0 {
                debugLog("decode throttled because renderer queue is full")
            }
            return false
        }

        decodeAttemptCount += 1
        if decodeAttemptCount <= 10 || decodeAttemptCount % 50 == 0 {
            debugLog("decode attempt=\(decodeAttemptCount) queuedPackets=\(queuedPackets.count) playPacketIndex=\(playPacketIndex) converterRunOutOfData=\(converterRunOutOfData)")
        }

        if converterRunOutOfData, playPacketIndex < queuedPackets.count {
            converterRunOutOfData = false
            if let audioConverter {
                AudioConverterReset(audioConverter)
                debugLog("audio converter reset after running out of data")
            }
        }

        guard let audioConverter, let outputAudioFormat else {
            return false
        }

        if packetsToRewind > 0 {
            playPacketIndex = min(playPacketIndex + packetsToRewind, queuedPackets.count)
            packetsToRewind = 0
        }

        let rawOutput = UnsafeMutableRawPointer.allocate(byteCount: Int(outputBufferSize), alignment: MemoryLayout<Int16>.alignment)
        defer { rawOutput.deallocate() }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: outputAudioFormat.channelCount,
                mDataByteSize: outputBufferSize,
                mData: rawOutput
            )
        )

        var ioOutputDataPackets = max(1, outputBufferSize / max(outputAudioFormat.streamDescription.pointee.mBytesPerPacket, 1))

        let status = AudioConverterFillComplexBuffer(
            audioConverter,
            audioConverterInputCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &ioOutputDataPackets,
            &bufferList,
            nil
        )

        if decodeAttemptCount <= 10 || decodeAttemptCount % 50 == 0 || status != noErr {
            debugLog("AudioConverterFillComplexBuffer status=\(status) outputBytes=\(bufferList.mBuffers.mDataByteSize) outputPackets=\(ioOutputDataPackets)")
        }

        let totalOutputBytes = Int(bufferList.mBuffers.mDataByteSize)
        if status == noErr, totalOutputBytes > 0, ioOutputDataPackets > 0 {
            audioQueueConsumedPackets = true

            let frameCount = AVAudioFrameCount(totalOutputBytes / Int(outputAudioFormat.streamDescription.pointee.mBytesPerFrame))
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputAudioFormat, frameCapacity: frameCount) else {
                closeAndSignalError(.streamParse, description: "Failed to allocate PCM buffer")
                return false
            }

            pcmBuffer.frameLength = frameCount
            let destination = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
            guard destination.count > 0, let mData = destination[0].mData else {
                closeAndSignalError(.streamParse, description: "PCM buffer had no writable audio storage")
                return false
            }

            memcpy(mData, rawOutput, totalOutputBytes)
            destination[0].mDataByteSize = UInt32(totalOutputBytes)

            enqueueDecodedSamples(pcmBuffer, packetCount: ioOutputDataPackets)

            if !configuration.seekingFromCacheEnabled || contentLength <= 0 || cachedDataByteCount >= configuration.maxPrebufferedByteCount {
                cleanupCachedData()
            }

            return true
        }

        if status == noErr && totalOutputBytes == 0 {
            debugLog("decoder produced no output yet")
            return false
        }

        if status == kAudio_ParamError {
            decoderFailed = true
            debugLog("decoder hit kAudio_ParamError")
            closeAndSignalError(.terminated, description: "Stream terminated abruptly")
            return false
        }

        if status != noErr {
            debugLog("AudioConverterFillComplexBuffer failed status=\(status)")
            closeAndSignalError(.streamParse, description: "Audio converter failed (\(status))")
        }

        return false
    }

    private var decoderShouldRunInternal: Bool {
        if preloading ||
            !decoderShouldRun ||
            converterRunOutOfData ||
            decoderFailed ||
            state == .paused ||
            state == .stopped ||
            state == .seeking ||
            state == .failed ||
            state == .playbackCompleted {
            return false
        }

        return outputAudioFormat != nil
    }

    fileprivate func cleanupCachedData() {
        debugLog("cleanupCachedData skipped playPacketIndex=\(playPacketIndex) queuedPackets=\(queuedPackets.count)")
        return

        guard playPacketIndex > 0 else {
            return
        }

        let removableCount = min(playPacketIndex, queuedPackets.count)
        guard removableCount > 0 else {
            return
        }

        for index in 0 ..< removableCount {
            cachedDataByteCount = max(0, cachedDataByteCount - queuedPackets[index].data.count)
        }

        queuedPackets.removeFirst(removableCount)
        playPacketIndex = 0
        debugLog("cleaned cached packets count=\(removableCount) remaining=\(queuedPackets.count)")
    }

    fileprivate func handlePropertyChange(_ propertyID: AudioFileStreamPropertyID, flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>?) {
        guard let audioFileStream else {
            return
        }

        switch propertyID {
        case kAudioFileStreamProperty_BitRate:
            debugLog("property: bitrate")
            var bitRate: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileStreamGetProperty(audioFileStream, propertyID, &size, &bitRate) == noErr {
                reportBitrate(bitRate)
            }
        case kAudioFileStreamProperty_DataOffset:
            debugLog("property: data offset")
            var offset: Int64 = 0
            var size = UInt32(MemoryLayout<Int64>.size)
            if AudioFileStreamGetProperty(audioFileStream, propertyID, &size, &offset) == noErr {
                dataOffset = offset
            }
        case kAudioFileStreamProperty_AudioDataByteCount:
            debugLog("property: audio data byte count")
            var byteCount: Int64 = 0
            var size = UInt32(MemoryLayout<Int64>.size)
            if AudioFileStreamGetProperty(audioFileStream, propertyID, &size, &byteCount) == noErr {
                audioDataByteCountStorage = byteCount
            }
        case kAudioFileStreamProperty_AudioDataPacketCount:
            debugLog("property: audio data packet count")
            var packetCount: Int64 = 0
            var size = UInt32(MemoryLayout<Int64>.size)
            if AudioFileStreamGetProperty(audioFileStream, propertyID, &size, &packetCount) == noErr {
                audioDataPacketCount = packetCount
            }
        case kAudioFileStreamProperty_ReadyToProducePackets:
            debugLog("property: ready to produce packets")
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_DataFormat, &size, &asbd)
            guard status == noErr else {
                closeAndSignalError(.open, description: "Unable to read source format (\(status))")
                return
            }

            do {
                try configureConverter(with: asbd)
            } catch let error as AudioStreamFailure {
                closeAndSignalError(error.code, description: error.description)
            } catch {
                closeAndSignalError(.open, description: error.localizedDescription)
            }
        default:
            _ = flags
        }
    }

    fileprivate func handlePackets(
        numberOfBytes: UInt32,
        numberOfPackets: UInt32,
        inputData: UnsafeRawPointer,
        packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard numberOfPackets > 0 else {
            debugLog("packet callback with zero packets numberOfBytes=\(numberOfBytes)")
            return
        }
        debugLog("packet callback bytes=\(numberOfBytes) packets=\(numberOfPackets)")

        let generatedDescriptions: [AudioStreamPacketDescription]
        if let packetDescriptions {
            generatedDescriptions = Array(UnsafeBufferPointer(start: packetDescriptions, count: Int(numberOfPackets)))
        } else {
            let packetSize = numberOfPackets > 0 ? Int(numberOfBytes / numberOfPackets) : 0
            generatedDescriptions = (0 ..< Int(numberOfPackets)).map { index in
                AudioStreamPacketDescription(
                    mStartOffset: Int64(index * packetSize),
                    mVariableFramesInPacket: 0,
                    mDataByteSize: UInt32(packetSize)
                )
            }
        }

        for description in generatedDescriptions {
            let start = Int(description.mStartOffset)
            let size = Int(description.mDataByteSize)
            let data = Data(bytes: inputData.advanced(by: start), count: size)
            let storedDescription = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: description.mVariableFramesInPacket,
                mDataByteSize: description.mDataByteSize
            )

            if bitRate == 0, packetDuration > 0, bitrateSamples.count < 50 {
                appendEstimatedBitrate(8.0 * Double(description.mDataByteSize) / packetDuration)
            }

            queuedPackets.append(
                QueuedPacket(
                    identifier: packetIdentifier,
                    data: data,
                    description: storedDescription,
                    packetCount: 1,
                    frameCount: 0
                )
            )
            cachedDataByteCount += data.count
            packetIdentifier += 1
        }

        debugLog("queued packets total=\(queuedPackets.count) cachedBytes=\(cachedDataByteCount)")

        determineBufferingLimits()
    }

    fileprivate func provideConverterInput(
        ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        ioData: UnsafeMutablePointer<AudioBufferList>,
        outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        guard playPacketIndex < queuedPackets.count else {
            converterRunOutOfData = true
            debugLog("converter input ran out of queued packets")
            ioNumberDataPackets.pointee = 0
            ioData.pointee.mBuffers.mDataByteSize = 0
            return noErr
        }

        let packet = queuedPackets[playPacketIndex]
        playPacketIndex += 1
        cachedDataByteCount = max(0, cachedDataByteCount - packet.data.count)
        converterInputCount += 1
        if converterInputCount <= 10 || converterInputCount % 50 == 0 {
            debugLog("converter input packet=\(converterInputCount) size=\(packet.data.count) descBytes=\(packet.description.mDataByteSize) cachedDataByteCount=\(cachedDataByteCount)")
        }

        if cachedDataByteCount < configuration.maxPrebufferedByteCount / 2 {
            Task { @MainActor [weak self] in
                await self?.source?.setReceivingEnabled(true)
            }
        }

        ioData.pointee.mNumberBuffers = 1
        ioNumberDataPackets.pointee = 1
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: (packet.data as NSData).bytes)
        ioData.pointee.mBuffers.mDataByteSize = packet.description.mDataByteSize
        ioData.pointee.mBuffers.mNumberChannels = sourceFormat?.channelCount ?? 0

        if let outDataPacketDescription {
            currentInputPacketDescriptionPointer.pointee = packet.description
            outDataPacketDescription.pointee = currentInputPacketDescriptionPointer
        }

        return noErr
    }

    private func packetDuration(for framesPerPacket: UInt32, sampleRate: Double) -> Double {
        guard framesPerPacket > 0 else {
            return 0
        }

        return Double(framesPerPacket) / sampleRate
    }
}

private func audioFileStreamPropertyCallback(
    inClientData: UnsafeMutableRawPointer,
    inAudioFileStream: AudioFileStreamID,
    inPropertyID: AudioFileStreamPropertyID,
    ioFlags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    let stream = Unmanaged<AudioStream>.fromOpaque(inClientData).takeUnretainedValue()
    MainActor.assumeIsolated {
        stream.handlePropertyChange(inPropertyID, flags: ioFlags)
    }
}

private func audioFileStreamPacketsCallback(
    inClientData: UnsafeMutableRawPointer,
    inNumberBytes: UInt32,
    inNumberPackets: UInt32,
    inInputData: UnsafeRawPointer,
    inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {
    let stream = Unmanaged<AudioStream>.fromOpaque(inClientData).takeUnretainedValue()
    MainActor.assumeIsolated {
        stream.handlePackets(
            numberOfBytes: inNumberBytes,
            numberOfPackets: inNumberPackets,
            inputData: inInputData,
            packetDescriptions: inPacketDescriptions
        )
    }
}

private func audioConverterInputCallback(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData else {
        ioNumberDataPackets.pointee = 0
        ioData.pointee.mBuffers.mDataByteSize = 0
        return noErr
    }

    let stream = Unmanaged<AudioStream>.fromOpaque(inUserData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        stream.provideConverterInput(
            ioNumberDataPackets: ioNumberDataPackets,
            ioData: ioData,
            outDataPacketDescription: outDataPacketDescription
        )
    }
}

extension AudioStream: InputStreamDelegate {
    public func streamIsReadyRead(_ stream: any AudioStreamSource) {
        sourceDidBecomeReady()
    }

    public func stream(_ stream: any AudioStreamSource, hasBytesAvailable data: Data) {
        sourceDidReceive(bytes: data)
    }

    public func streamEndEncountered(_ stream: any AudioStreamSource) {
        sourceDidEnd()
    }

    public func stream(_ stream: any AudioStreamSource, errorOccurred error: Error) {
        sourceDidFail(error)
    }

    public func stream(_ stream: any AudioStreamSource, metadataAvailable metadata: [String : String]) {
        sourceDidReceive(metadata: metadata)
    }

    public func stream(_ stream: any AudioStreamSource, metadataByteSizeAvailable sizeInBytes: Int64) {
        sourceDidReceive(metadataByteSize: sizeInBytes)
    }
}

extension AudioStream: AudioQueueDelegate {
    public func audioQueueStateChanged(_ state: AudioRendererState) {
        rendererStateChanged(state)
    }

    public func audioQueueBuffersEmpty() {
        Task { @MainActor [weak self] in
            await self?.rendererBuffersEmpty()
        }
    }

    public func audioQueueInitializationFailed(_ error: Error) {
        rendererInitializationFailed(error)
    }

    public func audioQueueFinishedPlayingPacket() {
        rendererFinishedPlayingPacket()
    }
}
