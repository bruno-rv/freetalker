import Foundation

/// BYOK cloud transcription via an OpenAI-compatible `/audio/transcriptions` endpoint.
/// Base URL and API key come from Settings; the key is stored in the Keychain.
/// See WhisperKitEngine's header comment for why the class is nonisolated + `@unchecked Sendable`.
final class CloudSTTEngine: ObservableObject, TranscriptionEngine, @unchecked Sendable {
    let name = "Cloud STT"
    @MainActor @Published private(set) var statusText: String = "Ready"

    enum CloudSTTError: LocalizedError {
        case missingAPIKey
        case badResponse(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "No cloud STT API key set in Settings."
            case .badResponse(let code, let body): "Cloud STT request failed (\(code)): \(body)"
            }
        }
    }

    func transcribe(samples: [Float]) async throws -> TranscriptionOutput {
        guard let apiKey = Keychain.get(account: Keychain.Account.cloudSTTKey), !apiKey.isEmpty else {
            throw CloudSTTError.missingAPIKey
        }
        await setStatus("Uploading…")
        defer { Task { await setStatus("Ready") } }

        let baseURL = await AppSettings.shared.cloudSTTBaseURL
        guard let url = URL(string: baseURL)?.appendingPathComponent("audio/transcriptions") else {
            throw CloudSTTError.badResponse(0, "Invalid base URL")
        }

        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
        let boundary = "FreeTalker-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, wavData: wavData)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudSTTError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }

        struct TranscriptionResponse: Decodable {
            let text: String
            let language: String?
        }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return TranscriptionOutput(text: decoded.text, language: decoded.language ?? "en")
    }

    @MainActor
    private func setStatus(_ text: String) {
        statusText = text
    }

    private func multipartBody(boundary: String, wavData: Data) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("whisper-1\r\n")

        // The default response format is plain text/minimal JSON with no `language` field on
        // most OpenAI-compatible servers; verbose_json is what actually returns it. See Round 1
        // Codex finding 11. `decoded.language ?? "en"` below still covers servers that omit it.
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("verbose_json\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }
}

/// Minimal 16-bit PCM WAV encoder — the only container CloudSTTEngine needs for upload.
enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: UInt32) -> Data {
        var data = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let subchunk2Size = UInt32(samples.count * 2)
        let chunkSize = 36 + subchunk2Size

        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        func appendString(_ s: String) { data.append(Data(s.utf8)) }

        appendString("RIFF")
        append(chunkSize.littleEndian)
        appendString("WAVE")
        appendString("fmt ")
        append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian) // PCM
        append(channels.littleEndian)
        append(sampleRate.littleEndian)
        append(byteRate.littleEndian)
        append(blockAlign.littleEndian)
        append(bitsPerSample.littleEndian)
        appendString("data")
        append(subchunk2Size.littleEndian)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * Float(Int16.max))
            append(intSample.littleEndian)
        }
        return data
    }
}
