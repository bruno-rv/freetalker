import Foundation

protocol Translating: Sendable {
    func process(
        source: String,
        template: Template,
        policy: OutputProcessingPolicy,
        snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String
}

struct TranslationService: Translating {
    enum Error: Swift.Error, Equatable {
        case translationRequired
        case unavailable(CloudLLMEligibility)
        case emptyOutput
    }

    typealias Process = @Sendable (
        _ request: PostProcessingRequest,
        _ snapshot: CloudLLMSettingsSnapshot,
        _ apiKey: String?
    ) async throws -> String

    private let cloudProcess: Process

    init(process: @escaping Process = Self.processWithCloudLLM) {
        cloudProcess = process
    }

    func process(
        source: String,
        template: Template,
        policy: OutputProcessingPolicy,
        snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String {
        guard case .translate = policy else { throw Error.translationRequired }

        let apiKey: String?
        switch snapshot.eligibility {
        case .eligible(let eligibleKey):
            apiKey = eligibleKey
        case .invalidConfiguration:
            throw Error.unavailable(.invalidConfiguration)
        case .missingAPIKey:
            throw Error.unavailable(.missingAPIKey)
        }

        let request = PostProcessingRequest(
            transcript: source,
            template: template,
            appName: nil,
            languagePolicy: policy
        )
        let output = try await cloudProcess(request, snapshot, apiKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw Error.emptyOutput }
        return output
    }

    private static func processWithCloudLLM(
        request: PostProcessingRequest,
        snapshot: CloudLLMSettingsSnapshot,
        apiKey: String?
    ) async throws -> String {
        try await CloudLLMProcessor(snapshot: snapshot).processEligible(request, apiKey: apiKey)
    }
}
