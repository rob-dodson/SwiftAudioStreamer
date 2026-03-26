import AVFoundation
import Foundation

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
        .init()
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var outputFormat: AVAudioFormat?
    private var prepared = false
    private var scheduledBufferCount = 0
    private let maxScheduledBufferCount = 8

    public init() {
    }

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
            return
        }

        playerNode.stop()
        engine.stop()
        scheduledBufferCount = 0
        state = .idle
        debugLog("queue stopped immediately=\(immediately)")
        delegate?.audioQueueStateChanged(.idle)

        if immediately {
            engine.reset()
            prepared = false
        }
    }
}
