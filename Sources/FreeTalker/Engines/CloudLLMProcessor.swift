import Foundation

/// BYOK cloud post-processing. One generic implementation covering both supported shapes —
/// Anthropic's Messages API and OpenAI-compatible chat completions — behind a provider enum,
/// per PLAN.md step 4 ("one generic implementation with provider enum").
struct CloudLLMProcessor: PostProcessor {
    enum CloudLLMError: LocalizedError {
        case missingAPIKey
        case badResponse(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "No cloud LLM API key set in Settings."
            case .badResponse(let code, let body): "Cloud LLM request failed (\(code)): \(body)"
            }
        }
    }

    func process(transcript: String, template: Template, appName: String?) async throws -> String {
        guard let apiKey = Keychain.get(account: Keychain.Account.cloudLLMKey), !apiKey.isEmpty else {
            throw CloudLLMError.missingAPIKey
        }

        let settings = await AppSettings.shared
        let instructions = buildProcessorInstructions(
            template: template,
            vocabulary: await settings.vocabulary,
            trailing: "Always respond in the same language as the transcript. Output only the result, no commentary.",
            appName: appName
        )

        switch await settings.llmProvider {
        case .anthropic:
            return try await callAnthropic(apiKey: apiKey, baseURL: await settings.cloudLLMBaseURL, model: await settings.cloudLLMModel, instructions: instructions, transcript: transcript)
        case .openAICompatible:
            return try await callOpenAICompatible(apiKey: apiKey, baseURL: await settings.cloudLLMBaseURL, model: await settings.cloudLLMModel, instructions: instructions, transcript: transcript)
        }
    }

    private func callAnthropic(apiKey: String, baseURL: String, model: String, instructions: String, transcript: String) async throws -> String {
        guard let url = URL(string: baseURL)?.appendingPathComponent("messages") else {
            throw CloudLLMError.badResponse(0, "Invalid base URL")
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
        try Self.checkStatus(response, data: data)

        struct AnthropicResponse: Decodable {
            struct ContentBlock: Decodable { let text: String? }
            let content: [ContentBlock]
        }
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return decoded.content.compactMap(\.text).joined()
    }

    private func callOpenAICompatible(apiKey: String, baseURL: String, model: String, instructions: String, transcript: String) async throws -> String {
        guard let url = URL(string: baseURL)?.appendingPathComponent("chat/completions") else {
            throw CloudLLMError.badResponse(0, "Invalid base URL")
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
        try Self.checkStatus(response, data: data)

        struct ChatResponse: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudLLMError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
