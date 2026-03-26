import Foundation

@MainActor
public final class URLSessionInputStream: NSObject, AudioStreamSource {
    public weak var delegate: InputStreamDelegate?
    public var url: URL?
    public private(set) var contentType: String?
    public private(set) var contentLength: Int64?
    public private(set) var position = InputStreamPosition()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 0
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var receivingEnabled = true
    private var pendingChunks: [Data] = []
    private var readySignaled = false
    private var completionDelivered = false
    private var metadataByteCount: Int64 = 0
    private var icyMetadataInterval = 0
    private var audioBytesUntilMetadata = 0
    private var metadataBytesRemaining = 0
    private var icyMetadataBuffer = Data()
    private var lastMetadata: [String: String] = [:]
    public var debugLoggingEnabled = false

    public override init() {
        super.init()
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else {
            return
        }

        fputs("[InputStream] \(message)\n", stderr)
    }

    public func open(at position: InputStreamPosition?) async throws {
        guard let url else {
            throw AudioStreamFailure(code: .open, description: "Missing stream URL")
        }

        await close()
        debugLog("opening url=\(url.absoluteString) position.start=\(position?.start ?? 0) position.end=\(position?.end.map(String.init) ?? "nil")")

        self.position = position ?? InputStreamPosition()
        readySignaled = false
        completionDelivered = false
        metadataByteCount = 0
        icyMetadataInterval = 0
        audioBytesUntilMetadata = 0
        metadataBytesRemaining = 0
        icyMetadataBuffer.removeAll(keepingCapacity: false)
        lastMetadata.removeAll(keepingCapacity: false)
        pendingChunks.removeAll(keepingCapacity: false)
        receivingEnabled = true

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")

        if let rangeValue = byteRangeHeader(for: self.position) {
            request.setValue(rangeValue, forHTTPHeaderField: "Range")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    public func close() async {
        debugLog("closing current task")
        task?.cancel()
        task = nil

        if let continuation {
            self.continuation = nil
            continuation.resume()
        }
    }

    public func setReceivingEnabled(_ enabled: Bool) async {
        receivingEnabled = enabled
        debugLog("receivingEnabled=\(enabled) pendingChunks=\(pendingChunks.count)")

        guard enabled, !pendingChunks.isEmpty else {
            return
        }

        let chunks = pendingChunks
        pendingChunks.removeAll(keepingCapacity: false)
        for chunk in chunks {
            await MainActor.run {
                delegate?.stream(self, hasBytesAvailable: chunk)
            }
        }
    }

    private func byteRangeHeader(for position: InputStreamPosition) -> String? {
        guard position.start > 0 || position.end != nil else {
            return nil
        }

        if let end = position.end {
            return "bytes=\(position.start)-\(end)"
        }

        return "bytes=\(position.start)-"
    }

    private func finishOpenIfNeeded() {
        guard let continuation, !readySignaled else {
            return
        }

        readySignaled = true
        self.continuation = nil
        debugLog("open finished successfully")
        continuation.resume()
    }

    private func failOpenIfNeeded(_ error: Error) {
        if let continuation {
            self.continuation = nil
            debugLog("open failed: \(error.localizedDescription)")
            continuation.resume(throwing: error)
        }
    }

    private func deliverChunk(_ data: Data) {
        if icyMetadataInterval > 0 {
            processICYData(data)
            return
        }

        if receivingEnabled {
            debugLog("delivering chunk size=\(data.count)")
            delegate?.stream(self, hasBytesAvailable: data)
        } else {
            debugLog("buffering chunk size=\(data.count) because receiving is disabled")
            pendingChunks.append(data)
        }
    }

    private func updateMetadata(from response: URLResponse) {
        contentType = response.mimeType
        debugLog("response mimeType=\(contentType ?? "<nil>") expectedLength=\(response.expectedContentLength)")

        let expectedLength = response.expectedContentLength
        if expectedLength > 0 {
            contentLength = expectedLength
        }

        var metadata: [String: String] = [:]

        if let httpResponse = response as? HTTPURLResponse {
            if let metadataIntervalValue = httpResponse.value(forHTTPHeaderField: "icy-metaint"),
               let interval = Int(metadataIntervalValue),
               interval > 0 {
                icyMetadataInterval = interval
                audioBytesUntilMetadata = interval
                debugLog("icy metadata interval=\(interval)")
            }

            if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
               let total = parseContentRange(contentRange) {
                contentLength = total
            }

            metadataByteCount = httpResponse.allHeaderFields.reduce(into: 0) { partial, item in
                partial += Int64("\(item.key): \(item.value)\r\n".utf8.count)
            }

            for (key, value) in httpResponse.allHeaderFields {
                metadata["\(key)".lowercased()] = "\(value)"
            }
        }

        if let contentType {
            metadata["content-type"] = contentType
        }

        let metadataSnapshot = metadata
        let metadataByteCount = metadataByteCount

        delegate?.stream(self, metadataAvailable: metadataSnapshot)
        delegate?.stream(self, metadataByteSizeAvailable: metadataByteCount)
        delegate?.streamIsReadyRead(self)
        finishOpenIfNeeded()
    }

    private func parseContentRange(_ header: String) -> Int64? {
        guard let totalString = header.split(separator: "/").last, totalString != "*" else {
            return nil
        }

        return Int64(totalString)
    }

    private func processICYData(_ data: Data) {
        var offset = 0
        var audioOutput = Data()

        while offset < data.count {
            if metadataBytesRemaining > 0 {
                let count = min(metadataBytesRemaining, data.count - offset)
                icyMetadataBuffer.append(data[offset ..< offset + count])
                metadataBytesRemaining -= count
                offset += count

                if metadataBytesRemaining == 0 {
                    emitICYMetadataIfNeeded()
                    icyMetadataBuffer.removeAll(keepingCapacity: false)
                }
                continue
            }

            if audioBytesUntilMetadata == 0 {
                metadataBytesRemaining = Int(data[offset]) * 16
                offset += 1
                audioBytesUntilMetadata = icyMetadataInterval
                icyMetadataBuffer.removeAll(keepingCapacity: true)
                continue
            }

            let count = min(audioBytesUntilMetadata, data.count - offset)
            audioOutput.append(data[offset ..< offset + count])
            audioBytesUntilMetadata -= count
            offset += count
        }

        guard !audioOutput.isEmpty else {
            return
        }

        if receivingEnabled {
            debugLog("delivering audio chunk size=\(audioOutput.count) after stripping ICY metadata")
            delegate?.stream(self, hasBytesAvailable: audioOutput)
        } else {
            debugLog("buffering audio chunk size=\(audioOutput.count) because receiving is disabled")
            pendingChunks.append(audioOutput)
        }
    }

    private func emitICYMetadataIfNeeded() {
        guard !icyMetadataBuffer.isEmpty else {
            return
        }

        let rawBytes = icyMetadataBuffer.prefix { $0 != 0 }
        guard !rawBytes.isEmpty else {
            return
        }

        let metadataString =
            String(data: rawBytes, encoding: .utf8) ??
            String(data: rawBytes, encoding: .isoLatin1)

        guard let metadataString else {
            debugLog("failed to decode ICY metadata block")
            return
        }

        var metadata = lastMetadata

        for entry in metadataString.split(separator: ";") {
            guard let separator = entry.firstIndex(of: "=") else {
                continue
            }

            let key = String(entry[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(entry[entry.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }

            if !key.isEmpty {
                metadata[key] = value
            }
        }

        guard metadata != lastMetadata else {
            return
        }

        lastMetadata = metadata
        debugLog("parsed ICY metadata keys=\(metadata.keys.sorted())")
        delegate?.stream(self, metadataAvailable: metadata)
    }
}

extension URLSessionInputStream: URLSessionDataDelegate, URLSessionTaskDelegate {
    public nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        await MainActor.run {
            self.updateMetadata(from: response)
        }
        return .allow
    }

    public nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Task { @MainActor in
            self.deliverChunk(data)
        }
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            self.task = nil
            self.debugLog("task completed error=\(error?.localizedDescription ?? "nil")")

            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    self.failOpenIfNeeded(AudioStreamFailure(code: .terminated, description: "Stream cancelled"))
                    return
                }

                self.failOpenIfNeeded(error)
                self.delegate?.stream(self, errorOccurred: error)
                return
            }

            self.finishOpenIfNeeded()

            guard !self.completionDelivered else {
                return
            }

            self.completionDelivered = true
            self.delegate?.streamEndEncountered(self)
        }
    }
}
