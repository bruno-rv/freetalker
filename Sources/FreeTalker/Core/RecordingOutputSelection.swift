struct RecordingOutputSelection: Equatable, Sendable {
    private(set) var pending: OutputLanguage?
    private(set) var current: OutputLanguage?

    var effective: OutputLanguage? {
        current ?? pending
    }

    mutating func select(_ language: OutputLanguage, isRecording: Bool) {
        if isRecording {
            current = language
        } else {
            pending = language
        }
    }

    @discardableResult
    mutating func start(default defaultLanguage: OutputLanguage) -> OutputLanguage {
        let selected = pending ?? defaultLanguage
        pending = nil
        current = selected
        return selected
    }

    mutating func resolveTerminal() {
        pending = nil
        current = nil
    }

    mutating func resolveTranslationFailure() -> OutputLanguage? {
        let recoveryOutput = current
        resolveTerminal()
        return recoveryOutput
    }
}
