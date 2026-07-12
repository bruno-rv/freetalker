import Foundation

enum ScratchpadAIAction: Equatable, Sendable {
    case improveWriting
    case expand
    case condense
    case custom(String)

    var label: String {
        switch self {
        case .improveWriting: "Improve writing"
        case .expand: "Expand"
        case .condense: "Condense"
        case .custom: "Custom"
        }
    }

    fileprivate var instruction: String? {
        switch self {
        case .improveWriting:
            "Improve the writing for clarity, grammar, and flow without changing its meaning or tone."
        case .expand:
            "Expand the text with useful detail while preserving its meaning and tone."
        case .condense:
            "Condense the text while preserving its essential meaning and tone."
        case .custom(let instruction):
            instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum ScratchpadTransformationError: Error, Equatable {
    case emptyInput
    case missingCustomInstruction
    case unavailable(CloudLLMEligibility)
    case emptyResponse
}

protocol ScratchpadTransforming: Sendable {
    func transform(
        _ text: String,
        action: ScratchpadAIAction,
        snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String
}

struct ScratchpadTransformationService: ScratchpadTransforming {
    typealias Process = @Sendable (
        _ transcript: String,
        _ template: Template,
        _ snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String

    private let process: Process

    init(process: @escaping Process = Self.processWithCloudLLM) {
        self.process = process
    }

    func transform(
        _ text: String,
        action: ScratchpadAIAction,
        snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScratchpadTransformationError.emptyInput
        }
        guard let instruction = action.instruction, !instruction.isEmpty else {
            throw ScratchpadTransformationError.missingCustomInstruction
        }
        guard snapshot.eligibility.isEligible else {
            throw ScratchpadTransformationError.unavailable(snapshot.eligibility)
        }

        let template = Template(
            id: "scratchpad-transformation",
            name: action.label,
            prompt: "\(instruction) Respond in the same language as the input. Return only the transformed text, with no commentary."
        )
        let output = try await process(text, template, snapshot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw ScratchpadTransformationError.emptyResponse }
        return output
    }

    private static func processWithCloudLLM(
        transcript: String,
        template: Template,
        snapshot: CloudLLMSettingsSnapshot
    ) async throws -> String {
        try await CloudLLMProcessor(snapshot: snapshot).process(
            transcript: transcript,
            template: template,
            appName: nil
        )
    }
}

struct ScratchpadAIAvailability: Equatable, Sendable {
    let enabled: Bool
    let tooltip: String?
    let accessibilityHelp: String?

    static func make(
        eligibility: CloudLLMEligibility,
        hasInput: Bool,
        isInFlight: Bool = false,
        hasInstruction: Bool,
        providerName: String
    ) -> Self {
        let reason: String?
        if !hasInput {
            reason = "Enter text to transform."
        } else if isInFlight {
            reason = "A transformation is already in progress."
        } else if !hasInstruction {
            reason = "Enter a custom instruction."
        } else {
            switch eligibility {
            case .invalidConfiguration:
                reason = "Complete the API configuration in Settings."
            case .missingAPIKey:
                reason = "Add an API key for \(providerName) in Settings."
            case .eligible:
                reason = nil
            }
        }
        return Self(enabled: reason == nil, tooltip: reason, accessibilityHelp: reason)
    }
}
