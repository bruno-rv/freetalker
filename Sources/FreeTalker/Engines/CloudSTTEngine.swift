import Foundation

/// BYOK cloud transcription via an OpenAI-compatible `/audio/transcriptions` endpoint.
/// Base URL and API key come from Settings; the key is stored in the Keychain.
/// See WhisperKitEngine's header comment for why the class is nonisolated + `@unchecked Sendable`.
final class CloudSTTEngine: ObservableObject, TranscriptionEngine, @unchecked Sendable {
    let name = "Cloud STT"
    @MainActor @Published private(set) var statusText: String = "Ready"

    enum CloudSTTError: LocalizedError {
        case missingAPIKey
        case badResponse(status: Int, hint: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "No cloud STT API key set in Settings."
            case .badResponse(let status, let hint): "Cloud STT request failed (\(status)): \(hint)"
            }
        }

        /// Classifies an HTTP status into a short, non-sensitive hint — derived only from the
        /// status code, never the response body. Mirrors `ConnectionTestOutcome`'s 401/404
        /// special-casing.
        static func classifyHint(status: Int) -> String {
            switch status {
            case 401: return "check API key"
            case 404: return "check model/URL"
            case 0: return "invalid base URL"
            default: return "request failed"
            }
        }
    }

    /// `candidateLanguages` is ignored — the OpenAI-compatible `/audio/transcriptions` API only
    /// ever takes a single `forcedLanguage` (or provider auto-detect when nil); there's no
    /// candidate-set concept to constrain it with. See PLAN.md F5.3.
    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String]) async throws -> TranscriptionOutput {
        guard let apiKey = Keychain.get(account: Keychain.Account.cloudSTTKey), !apiKey.isEmpty else {
            throw CloudSTTError.missingAPIKey
        }
        await setStatus("Uploading…")
        defer { Task { await setStatus("Ready") } }

        let baseURL = await AppSettings.shared.cloudSTTBaseURL
        guard let url = URL(string: baseURL)?.appendingPathComponent("audio/transcriptions") else {
            throw CloudSTTError.badResponse(status: 0, hint: CloudSTTError.classifyHint(status: 0))
        }

        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
        let boundary = "FreeTalker-\(UUID().uuidString)"
        let vocabulary = await AppSettings.shared.vocabulary

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, wavData: wavData, vocabulary: vocabulary, forcedLanguage: forcedLanguage)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudSTTError.badResponse(status: code, hint: CloudSTTError.classifyHint(status: code))
        }

        struct TranscriptionResponse: Decodable {
            let text: String
            let language: String?
        }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let language = forcedLanguage ?? decoded.language ?? "en"
        return TranscriptionOutput(text: decoded.text, language: language)
    }

    @MainActor
    private func setStatus(_ text: String) {
        statusText = text
    }

    /// Connectivity check for Settings' "Test connection" button. `transcribe` only ever POSTs
    /// audio to `/audio/transcriptions`, which has no cheap no-upload variant — but the base URL
    /// follows the OpenAI-compatible convention (e.g. `.../v1`) that also serves `GET /models`,
    /// a standard, auth-gated, response-body-free endpoint most OpenAI-compatible servers
    /// (including OpenAI itself) implement — so this GETs that instead of uploading real audio.
    /// Returns the raw HTTP status; a thrown error means the request never got a response at all
    /// (see `ConnectionTestOutcome.fromTransportError`). Never reads the response body.
    static func testConnection(baseURL: String, apiKey: String) async throws -> Int {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBase)?.appendingPathComponent("models") else {
            throw CloudSTTError.badResponse(status: 0, hint: CloudSTTError.classifyHint(status: 0))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func multipartBody(boundary: String, wavData: Data, vocabulary: [String], forcedLanguage: String?) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("whisper-1\r\n")

        if let forcedLanguage {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(forcedLanguage)\r\n")
        }

        // Bias the cloud STT the same way as WhisperKitEngine's promptTokens — the
        // OpenAI-compatible `/audio/transcriptions` endpoint accepts a free-text `prompt` field
        // used as decoding context. Omitted entirely when vocabulary is empty.
        if !vocabulary.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("\(vocabulary.joined(separator: ", "))\r\n")
        }

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
