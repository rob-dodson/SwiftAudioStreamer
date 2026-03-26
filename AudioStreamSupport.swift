import AVFoundation
import AudioToolbox
import Foundation

public struct InputStreamPosition: Sendable, Equatable {
    public var start: Int64
    public var end: Int64?

    public init(start: Int64 = 0, end: Int64? = nil) {
        self.start = start
        self.end = end
    }
}

public struct PlaybackPosition: Sendable, Equatable {
    public var offset: Float
    public var timePlayed: TimeInterval

    public init(offset: Float = 0, timePlayed: TimeInterval = 0) {
        self.offset = offset
        self.timePlayed = timePlayed
    }
}

public enum AudioStreamErrorCode: Int, Sendable {
    case open = 1
    case streamParse = 2
    case network = 3
    case unsupportedFormat = 4
    case bouncing = 5
    case terminated = 6
}

public struct AudioStreamFailure: Error, Sendable, LocalizedError {
    public let code: AudioStreamErrorCode
    public let description: String

    public init(code: AudioStreamErrorCode, description: String) {
        self.code = code
        self.description = description
    }

    public var errorDescription: String? {
        description
    }
}

public struct AudioLevelMeterState: Sendable, Equatable {
    public var averagePower: Float
    public var peakPower: Float

    public init(averagePower: Float = 0, peakPower: Float = 0) {
        self.averagePower = averagePower
        self.peakPower = peakPower
    }
}

@MainActor
public protocol InputStreamDelegate: AnyObject {
    func streamIsReadyRead(_ stream: AudioStreamSource)
    func stream(_ stream: AudioStreamSource, hasBytesAvailable data: Data)
    func streamEndEncountered(_ stream: AudioStreamSource)
    func stream(_ stream: AudioStreamSource, errorOccurred error: Error)
    func stream(_ stream: AudioStreamSource, metadataAvailable metadata: [String: String])
    func stream(_ stream: AudioStreamSource, metadataByteSizeAvailable sizeInBytes: Int64)
}

public enum AudioRendererState: Sendable {
    case idle
    case running
    case paused
}

@MainActor
public protocol AudioQueueDelegate: AnyObject {
    func audioQueueStateChanged(_ state: AudioRendererState)
    func audioQueueBuffersEmpty()
    func audioQueueInitializationFailed(_ error: Error)
    func audioQueueFinishedPlayingPacket()
}

public struct AudioStreamConfiguration: Sendable {
    public var outputSampleRate: Double
    public var outputChannelCount: AVAudioChannelCount
    public var startupWatchdogPeriod: TimeInterval
    public var maxPrebufferedByteCount: Int
    public var requiredInitialPrebufferedByteCountForContinuousStream: Int
    public var requiredInitialPrebufferedByteCountForNonContinuousStream: Int
    public var requiredInitialPrebufferedPacketCount: Int
    public var bounceInterval: TimeInterval
    public var maxBounceCount: Int
    public var cacheEnabled: Bool
    public var seekingFromCacheEnabled: Bool
    public var requireStrictContentTypeChecking: Bool

    public init(
        outputSampleRate: Double = 44_100,
        outputChannelCount: AVAudioChannelCount = 2,
        startupWatchdogPeriod: TimeInterval = 30,
        maxPrebufferedByteCount: Int = 512_000,
        requiredInitialPrebufferedByteCountForContinuousStream: Int = 256_000,
        requiredInitialPrebufferedByteCountForNonContinuousStream: Int = 64_000,
        requiredInitialPrebufferedPacketCount: Int = 32,
        bounceInterval: TimeInterval = 10,
        maxBounceCount: Int = 4,
        cacheEnabled: Bool = true,
        seekingFromCacheEnabled: Bool = true,
        requireStrictContentTypeChecking: Bool = true
    ) {
        self.outputSampleRate = outputSampleRate
        self.outputChannelCount = outputChannelCount
        self.startupWatchdogPeriod = startupWatchdogPeriod
        self.maxPrebufferedByteCount = maxPrebufferedByteCount
        self.requiredInitialPrebufferedByteCountForContinuousStream = requiredInitialPrebufferedByteCountForContinuousStream
        self.requiredInitialPrebufferedByteCountForNonContinuousStream = requiredInitialPrebufferedByteCountForNonContinuousStream
        self.requiredInitialPrebufferedPacketCount = requiredInitialPrebufferedPacketCount
        self.bounceInterval = bounceInterval
        self.maxBounceCount = maxBounceCount
        self.cacheEnabled = cacheEnabled
        self.seekingFromCacheEnabled = seekingFromCacheEnabled
        self.requireStrictContentTypeChecking = requireStrictContentTypeChecking
    }
}

@MainActor
public protocol AudioStreamDelegate: AnyObject {
    func audioStream(_ stream: AudioStream, didChangeState state: AudioStream.State)
    func audioStream(_ stream: AudioStream, didReceiveError error: AudioStreamFailure)
    func audioStream(_ stream: AudioStream, didReceiveMetadata metadata: [String: String])
    func audioStream(_ stream: AudioStream, didProduceSamples buffer: AVAudioPCMBuffer, packetCount: AVAudioPacketCount)
    func audioStreamBitrateBecameAvailable(_ stream: AudioStream)
}

public extension AudioStreamDelegate {
    func audioStream(_ stream: AudioStream, didReceiveMetadata metadata: [String: String]) {}
    func audioStream(_ stream: AudioStream, didProduceSamples buffer: AVAudioPCMBuffer, packetCount: AVAudioPacketCount) {}
    func audioStreamBitrateBecameAvailable(_ stream: AudioStream) {}
}

@MainActor
public protocol AudioStreamSource: AnyObject {
    var delegate: InputStreamDelegate? { get set }
    var url: URL? { get set }
    var contentType: String? { get }
    var contentLength: Int64? { get }
    var position: InputStreamPosition { get }

    func open(at position: InputStreamPosition?) async throws
    func close() async
    func setReceivingEnabled(_ enabled: Bool) async
}

@MainActor
public protocol AudioStreamRenderer: AnyObject {
    var delegate: AudioQueueDelegate? { get set }
    var state: AudioRendererState { get }
    var isReadyForMoreData: Bool { get }
    var volume: Float { get set }
    var rate: Float { get set }
    var currentTimeSeconds: TimeInterval { get }
    var levels: AudioLevelMeterState { get }

    func prepare(outputFormat: AVAudioFormat) throws
    func enqueue(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)?)
    func start()
    func pause()
    func stop(immediately: Bool)
}

struct QueuedPacket {
    var identifier: UInt64
    var data: Data
    var description: AudioStreamPacketDescription
    var packetCount: AVAudioPacketCount
    var frameCount: AVAudioFrameCount
}
