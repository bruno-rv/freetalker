import Foundation

/// BYOK cloud post-processing. One generic implementation covering the two supported wire
/// formats — Anthropic's Messages API and OpenAI-compatible chat completions — behind a provider
/// enum, per PLAN.md step 4 ("one generic implementation with provider enum"). `.ollama` reuses
/// the OpenAI-compatible shape: verified empirically (unauthenticated `POST
/// https://ollama.com/v1/chat/completions` -> 401, not 404 — the endpoint exists and is
/// auth-gated). See PLAN.md step 1.
///
/// Holds a `CloudLLMSettingsSnapshot` captured by `AppCoordinator` on MainActor at
/// processor-selection time — `process` never reads `AppSettings` or the Keychain itself, so the
/// routing decision (`AppCoordinator.isCloudLLMConfigured`) and the request it drives always see
/// the same provider/base URL/model/key. See PLAN.md Amendment A1/A2, Codex round-5 finding 4.
struct CloudLLMProcessor: PostProcessor {
    let snapshot: CloudLLMSettingsSnapshot

    enum CloudLLMError: LocalizedError {
        case missingAPIKey(provider: String)
        case missingConfiguration(provider: String)
        /// Status code + provider label only — the response body is never carried into the
        /// error description, logged, or otherwise surfaced. See PLAN.md step 8, Round 2 Codex
        /// finding 5.
        case badResponse(provider: String, status: Int)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider): "No cloud LLM API key set for \(provider) in Settings."
            case .missingConfiguration(let provider): "Cloud LLM base URL or model not set for \(provider) in Settings."
            case .badResponse(let provider, let status): "Cloud LLM request failed (\(provider), status \(status))."
            }
        }
    }

    func process(transcript: String, template: Template, appName: String?) async throws -> String {
        // `snapshot` was captured on MainActor at processor-selection time (see doc comment
        // above) — no AppSettings/Keychain read here, just the trimmed values it already holds.
        let providerLabel = snapshot.provider.rawValue
        let baseURL = snapshot.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = snapshot.model.trimmingCharacters(in: .whitespacesAndNewlines)

        // All three providers require a model; base URL is likewise always required. See
        // PLAN.md step 2, Round 3 Codex finding 1.
        guard !baseURL.isEmpty, !model.isEmpty else {
            throw CloudLLMError.missingConfiguration(provider: providerLabel)
        }

        guard let apiKey = snapshot.key?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw CloudLLMError.missingAPIKey(provider: providerLabel)
        }

        let instructions = buildProcessorInstructions(
            template: template,
            vocabulary: snapshot.vocabulary,
            trailing: "Always respond in the same language as the transcript. Output only the result, no commentary.",
            appName: appName
        )

        switch snapshot.provider {
        case .anthropic:
            return try await callAnthropic(apiKey: apiKey, baseURL: baseURL, model: model, instructions: instructions, transcript: transcript, providerLabel: providerLabel)
        case .ollama, .openAICompatible:
            return try await callOpenAICompatible(apiKey: apiKey, baseURL: baseURL, model: model, instructions: instructions, transcript: transcript, providerLabel: providerLabel)
        }
    }

    private func callAnthropic(apiKey: String, baseURL: String, model: String, instructions: String, transcript: String, providerLabel: String) async throws -> String {
        guard let url = URL(string: baseURL)?.appendingPathComponent("messages") else {
            throw CloudLLMError.missingConfiguration(provider: providerLabel)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": instructions,
            "messages": [["role": "user", "content": transcript]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, provider: providerLabel)

        struct AnthropicResponse: Decodable {
            struct ContentBlock: Decodable { let text: String? }
            let content: [ContentBlock]
        }
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return decoded.content.compactMap(\.text).joined()
    }

    private func callOpenAICompatible(apiKey: String, baseURL: String, model: String, instructions: String, transcript: String, providerLabel: String) async throws -> String {
        guard let url = URL(string: baseURL)?.appendingPathComponent("chat/completions") else {
            throw CloudLLMError.missingConfiguration(provider: providerLabel)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": transcript]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, provider: providerLabel)

        struct ChatResponse: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    private static func checkStatus(_ response: URLResponse, provider: String) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudLLMError.badResponse(provider: provider, status: code)
        }
    }

    /// Connectivity check for Settings' "Test connection" button — same endpoint/auth headers as
    /// `process`, but a minimal fixed prompt, a small `max_tokens`, and a short (10s) timeout, so
    /// it verifies the key/base URL/model without running a real dictation's system prompt/
    /// vocabulary through it. Returns the raw HTTP status; a thrown error means the request never
    /// got a response at all (see `ConnectionTestOutcome.fromTransportError`). Never reads the
    /// response body.
    func testConnection() async throws -> Int {
        let providerLabel = snapshot.provider.rawValue
        let baseURL = snapshot.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = snapshot.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !model.isEmpty else {
            throw CloudLLMError.missingConfiguration(provider: providerLabel)
        }
        guard let apiKey = snapshot.key?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw CloudLLMError.missingAPIKey(provider: providerLabel)
        }

        var request: URLRequest
        switch snapshot.provider {
        case .anthropic:
            guard let url = URL(string: baseURL)?.appendingPathComponent("messages") else {
                throw CloudLLMError.missingConfiguration(provider: providerLabel)
            }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 8,
                "messages": [["role": "user", "content": "Reply with OK"]]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        case .ollama, .openAICompatible:
            guard let url = URL(string: baseURL)?.appendingPathComponent("chat/completions") else {
                throw CloudLLMError.missingConfiguration(provider: providerLabel)
            }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 8,
                "messages": [["role": "user", "content": "Reply with OK"]]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
