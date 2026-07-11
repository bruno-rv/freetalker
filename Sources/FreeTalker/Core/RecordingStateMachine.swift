import Foundation

enum RecordingState: Equatable {
    case idle
    case pttRecording
    case locked(ignoreNextKeyUp: Bool)
}

enum RecordingEvent: Equatable {
    case keyDown
    case keyUp(elapsed: TimeInterval)
    case pillClick
    case esc
    case capReached(generation: Int)
    case panelFinish
}

/// What the caller must actually do as a result of a transition. `RecordingStateMachine` never
/// performs these itself — pure in, pure out — `AppCoordinator` maps each action to the real
/// audio-capture/HUD/timer/insertion side effects.
enum RecordingAction: Equatable {
    case none
    /// idle -> pttRecording: start audio capture (unchanged from pre-Amendment-B PTT).
    case startCapture
    /// -> locked: recording continues uninterrupted; only the HUD/cap-timer state changes.
    case enterLocked
    /// -> idle: stop capture, transcribe, insert, record — the shared terminal "stop" path.
    case stopAndTranscribe
    /// -> idle: the `cancelRecording` terminal action (B1a) — no transcription, no Library entry.
    case cancel
}

enum RecordingStateMachine {
    static let tapThreshold: TimeInterval = 0.4

    static func transition(state: RecordingState, event: RecordingEvent, currentGeneration: Int) -> (state: RecordingState, action: RecordingAction) {
        switch (state, event) {
        case (.idle, .keyDown):
            return (.pttRecording, .startCapture)

        case (.pttRecording, .keyUp(let elapsed)):
            return elapsed < tapThreshold
                ? (.locked(ignoreNextKeyUp: false), .enterLocked)
                : (.idle, .stopAndTranscribe)

        case (.pttRecording, .pillClick):
            return (.locked(ignoreNextKeyUp: true), .enterLocked)

        case (.locked, .keyDown):
            return (.idle, .stopAndTranscribe)

        case (.locked, .keyUp):
            // Unconditional no-op — true regardless of `ignoreNextKeyUp` — but resets the flag so
            // it never outlives the one keyUp it was guarding against.
            return (.locked(ignoreNextKeyUp: false), .none)

        case (.locked, .pillClick):
            return (.idle, .stopAndTranscribe)

        case (.pttRecording, .esc), (.locked, .esc):
            return (.idle, .cancel)

        case (.locked, .capReached(let generation)):
            return generation == currentGeneration ? (.idle, .stopAndTranscribe) : (state, .none)

        case (.pttRecording, .panelFinish), (.locked, .panelFinish):
            return (.idle, .stopAndTranscribe)

        default:
            // idle+{keyUp,pillClick,esc,capReached,panelFinish}, pttRecording+capReached: no-op.
            return (state, .none)
        }
    }
}
