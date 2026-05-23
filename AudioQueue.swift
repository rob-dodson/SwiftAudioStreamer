import AVFoundation
import Foundation

private final class AudioLevelMeterStore: @unchecked Sendable {
    private let lock = NSLock()
    private var state = AudioLevelMeterState.silence

    func load() -> AudioLevelMeterState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func store(_ newState: AudioLevelMeterState) {
        lock.lock()
        state = newState
        lock.unlock()
    }
}

@MainActor
public final class EngineAudioQueue: AudioStreamRenderer {
    public weak var delegate: AudioQueueDelegate?
    public var debugLoggingEnabled = false
    public private(set) var state: AudioRendererState = .idle
    public var isReadyForMoreData: Bool {
        scheduledBufferCount < maxScheduledBufferCount
    }
    public var volume: Float = 1.0 {
        didSet {
            playerNode.volume = volume
        }
    }

    public var rate: Float = 1.0 {
        didSet {
            debugLog("rate set to \(rate), time-pitch disabled in simplified renderer")
        }
    }

    public var currentTimeSeconds: TimeInterval {
        guard
            let nodeTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return 0
        }

        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    public var levels: AudioLevelMeterState {
        meterStore.load()
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let meterStore = AudioLevelMeterStore()
    private var outputFormat: AVAudioFormat?
    private var prepared = false
    private var scheduledBufferCount = 0
    private let maxScheduledBufferCount = 8

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else {
            return
        }

        fputs("[AudioQueue] \(message)\n", stderr)
    }

    public func prepare(outputFormat: AVAudioFormat) throws {
        if prepared, self.outputFormat == outputFormat {
            debugLog("prepare skipped because queue is already prepared")
            return
        }

        stop(immediately: true)
        engine.reset()
        debugLog("preparing output sampleRate=\(outputFormat.sampleRate) channels=\(outputFormat.channelCount)")

        self.outputFormat = outputFormat
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        installLevelTap(format: outputFormat)

        do {
            try engine.start()
            prepared = true
            state = .idle
            debugLog("engine started during prepare")
        } catch {
            debugLog("prepare failed: \(error.localizedDescription)")
            delegate?.audioQueueInitializationFailed(error)
            throw error
        }
    }

    public func enqueue(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)?) {
        guard prepared else {
            let error = AudioStreamFailure(code: .open, description: "Audio queue was not prepared")
            debugLog("enqueue failed because queue is not prepared")
            delegate?.audioQueueInitializationFailed(error)
            return
        }

        scheduledBufferCount += 1
        debugLog("enqueue buffer frameLength=\(buffer.frameLength) scheduledBufferCount=\(scheduledBufferCount)")
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion?()
                    return
                }

                self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
                self.debugLog("buffer completed scheduledBufferCount=\(self.scheduledBufferCount)")
                self.delegate?.audioQueueFinishedPlayingPacket()
                if self.scheduledBufferCount == 0 {
                    self.delegate?.audioQueueBuffersEmpty()
                }
                completion?()
            }
        }
    }

    public func start() {
        guard prepared else {
            return
        }

        if !engine.isRunning {
            do {
                try engine.start()
                debugLog("engine restarted in start()")
            } catch {
                debugLog("engine start failed: \(error.localizedDescription)")
                delegate?.audioQueueInitializationFailed(error)
                return
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
            debugLog("player node started")
        }

        if state != .running {
            state = .running
            delegate?.audioQueueStateChanged(.running)
        }
    }

    public func pause() {
        guard prepared else {
            return
        }

        if playerNode.isPlaying {
            playerNode.pause()
            debugLog("player node paused")
        } else {
            playerNode.play()
            debugLog("player node resumed")
        }

        state = playerNode.isPlaying ? .running : .paused
        delegate?.audioQueueStateChanged(state)
    }

    public func stop(immediately: Bool) {
        guard prepared || engine.isRunning else {
            state = .idle
            resetMetering()
            return
        }

        playerNode.stop()
        playerNode.removeTap(onBus: 0)
        engine.stop()
        scheduledBufferCount = 0
        resetMetering()
        state = .idle
        debugLog("queue stopped immediately=\(immediately)")
        delegate?.audioQueueStateChanged(.idle)

        if immediately {
            engine.reset()
            prepared = false
        }
    }

    private func installLevelTap(format: AVAudioFormat) {
        playerNode.removeTap(onBus: 0)
        let meterStore = self.meterStore
        playerNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            meterStore.store(Self.makeMeterState(from: buffer))
        }
    }

    private func resetMetering() {
        meterStore.store(.silence)
    }

    nonisolated private static func makeMeterState(from buffer: AVAudioPCMBuffer) -> AudioLevelMeterState {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return .silence
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else {
                return .silence
            }
            return makeMeterState(
                channelCount: Int(buffer.format.channelCount),
                frameLength: frameLength
            ) { channel, frame in
                Float(channelData[channel][frame])
            }
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else {
                return .silence
            }
            return makeMeterState(
                channelCount: Int(buffer.format.channelCount),
                frameLength: frameLength
            ) { channel, frame in
                Float(channelData[channel][frame]) / Float(Int16.max)
            }
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else {
                return .silence
            }
            return makeMeterState(
                channelCount: Int(buffer.format.channelCount),
                frameLength: frameLength
            ) { channel, frame in
                Float(channelData[channel][frame]) / Float(Int32.max)
            }
        default:
            return .silence
        }
    }

    nonisolated private static func makeMeterState(
        channelCount: Int,
        frameLength: Int,
        sample: (_ channel: Int, _ frame: Int) -> Float
    ) -> AudioLevelMeterState {
        let minimumPower: Float = -80
        var sumSquares: Float = 0
        var peak: Float = 0
        let sampleCount = max(channelCount * frameLength, 1)

        for channel in 0..<channelCount {
            for frame in 0..<frameLength {
                let amplitude = abs(sample(channel, frame))
                sumSquares += amplitude * amplitude
                peak = max(peak, amplitude)
            }
        }

        let rms = sqrt(sumSquares / Float(sampleCount))
        let averagePower = max(minimumPower, 20 * log10(max(rms, 0.000_1)))
        let peakPower = max(minimumPower, 20 * log10(max(peak, 0.000_1)))
        return .init(averagePower: averagePower, peakPower: peakPower)
    }
}
