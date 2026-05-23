import Foundation

final class HarnessAudioStreamSource: AudioStreamSource {
    var url: URL?
    private(set) var contentType: String?
    private(set) var contentLength: Int64?
    private(set) var position = InputStreamPosition()

    func open(at position: InputStreamPosition?) async throws {
        guard let url else {
            throw AudioStreamFailure(code: .open, description: "Missing stream URL")
        }

        self.position = position ?? InputStreamPosition()

        do {
            try await loadMetadata(url: url, position: position)
        } catch {
            try await loadMetadataWithRangeProbe(url: url, position: position)
        }
    }

    func close() async {}

    func setReceivingEnabled(_ enabled: Bool) async {}

    private func loadMetadata(url: URL, position: InputStreamPosition?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        applyRange(position, to: &request)

        let (_, response) = try await URLSession.shared.data(for: request)
        try updateMetadata(from: response)
    }

    private func loadMetadataWithRangeProbe(url: URL, position: InputStreamPosition?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let position {
            applyRange(position, to: &request)
        } else {
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        try updateMetadata(from: response)
    }

    private func updateMetadata(from response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AudioStreamFailure(code: .network, description: "Unexpected response type")
        }

        guard (200 ..< 400).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else {
            throw AudioStreamFailure(code: .open, description: "HTTP \(httpResponse.statusCode) while opening stream")
        }

        contentType = response.mimeType

        let expectedLength = response.expectedContentLength
        if expectedLength > 0 {
            contentLength = expectedLength
        } else {
            contentLength = httpResponse.totalContentLengthFromRange
        }
    }

    private func applyRange(_ position: InputStreamPosition?, to request: inout URLRequest) {
        guard let rangeValue = position?.byteRangeHeader else {
            return
        }

        request.setValue(rangeValue, forHTTPHeaderField: "Range")
    }
}
