import SwiftUI

struct TranslationControlsState: Equatable {
    let effectiveOutput: OutputLanguage
    let override: OutputLanguage?
    let availability: CloudFeatureAvailability
}

struct TranslationControlsPresentation: Equatable {
    struct OutputChoice: Equatable {
        let language: OutputLanguage
        let label: String
    }

    static let spokenLabel = "Speak:"
    static let outputLabel = "Output:"
    static let outputChoices = OutputLanguage.allCases.map {
        OutputChoice(language: $0, label: $0.displayName)
    }

    let state: TranslationControlsState

    var tooltip: String? { state.availability.tooltip }
    var accessibilityHelp: String? { state.availability.accessibilityHelp }

    func isEnabled(_ language: OutputLanguage) -> Bool {
        language == .sameAsSpoken || state.availability.enabled
    }

    func accessibilityPolicy(for language: OutputLanguage) -> OutputChoiceAccessibilityPolicy {
        let enabled = isEnabled(language)
        return OutputChoiceAccessibilityPolicy(
            wrapperIsEnabled: true,
            childCommandIsEnabled: enabled,
            label: language.displayName,
            value: enabled ? (state.effectiveOutput == language ? "Selected" : "Available") : "Unavailable",
            hint: enabled ? nil : accessibilityHelp,
            tooltip: enabled ? nil : tooltip
        )
    }
}

struct OutputChoiceAccessibilityPolicy: Equatable {
    let wrapperIsEnabled: Bool
    let childCommandIsEnabled: Bool
    let label: String
    let value: String
    let hint: String?
    let tooltip: String?
}

struct TranslationControls: View {
    let languagePin: String
    /// The configured Dictation Language Set's codes (F5.5) — the ONE source every spoken-
    /// language selector (this one included) reads from; no selector hardcodes its own list.
    /// See `DictationLanguagePresentation`.
    let languageOptions: [String]
    let state: TranslationControlsState
    let onLanguage: (String) -> Void
    let onOutput: (OutputLanguage) -> Void

    private var presentation: TranslationControlsPresentation {
        TranslationControlsPresentation(state: state)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(TranslationControlsPresentation.spokenLabel)
            Menu {
                spokenButton("Auto", code: "auto")
                ForEach(DictationLanguagePresentation.options(for: languageOptions), id: \.code) { option in
                    spokenButton(option.label, code: option.code)
                }
            } label: {
                Text(spokenName)
            }
            .menuStyle(.borderlessButton)
            .help("Choose dictation language")
            .accessibilityLabel("Choose dictation language")

            Text(TranslationControlsPresentation.outputLabel)
            Menu {
                ForEach(Self.outputChoices, id: \.language.rawValue) { choice in
                    outputChoice(choice)
                }
            } label: {
                Text(state.effectiveOutput.displayName)
            }
            .menuStyle(.borderlessButton)
            .help("Choose recording output language")
            .accessibilityLabel("Choose recording output language")
        }
        .font(.caption)
    }

    private static let outputChoices = TranslationControlsPresentation.outputChoices

    private var spokenName: String {
        languagePin == "auto" ? "Auto" : DictationLanguagePresentation.displayName(for: languagePin)
    }

    private func spokenButton(_ label: String, code: String) -> some View {
        Button { onLanguage(code) } label: {
            if languagePin == code { Label(label, systemImage: "checkmark") }
            else { Text(label) }
        }
        .help("Use \(label) for dictation")
        .accessibilityLabel("Use \(label) for dictation")
    }

    @ViewBuilder
    private func outputChoice(_ choice: TranslationControlsPresentation.OutputChoice) -> some View {
        let policy = presentation.accessibilityPolicy(for: choice.language)
        let button = Button { onOutput(choice.language) } label: {
            if state.effectiveOutput == choice.language {
                Label(choice.label, systemImage: "checkmark")
            } else {
                Text(choice.label)
            }
        }
        .disabled(!policy.childCommandIsEnabled)

        if !policy.childCommandIsEnabled,
           let tooltip = policy.tooltip,
           let accessibilityHelp = policy.hint {
            HStack { button }
                .help(tooltip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(policy.label))
                .accessibilityValue(Text(policy.value))
                .accessibilityHint(Text(accessibilityHelp))
        } else {
            button
        }
    }
}
