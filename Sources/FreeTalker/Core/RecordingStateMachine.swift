import Foundation

/// Hands-free recording states (Amendment B): tapping the hotkey (quick key-down/key-up) starts
/// a recording that keeps going after release — `locked` — until the user taps/clicks again,
/// presses Esc, or the duration cap fires. Holding the hotkey past `RecordingStateMachine.
/// tapThreshold` is the classic push-to-talk gesture, unchanged: release stops and transcribes.
///
/// `locked`'s `ignoreNextKeyUp` handles one specific case: clicking the HUD pill locks an
/// *in-progress* PTT recording while the hotkey is still physically held down — the inevitable
/// key release that follows must be a no-op (it already happened, semantically, at the click).
/// It is not load-bearing for `locked`'s general `keyUp -> no-op` transition below, which holds
/// unconditionally either way; it exists so that one specific keyUp is consumed/reset rather than
/// lingering indefinitely. See PLAN.md Amendment B1/B3/B6.
enum RecordingState: Equatable {
    case idle
    case pttRecording
    case locked(ignoreNextKeyUp: Bool)
}

/// Inputs the state machine reacts to. `elapsed` (seconds since key-down) and `generation`
/// (the recording session a cap-timer fire belongs to) are the only event payloads. See
/// PLAN.md Amendment B6.
enum RecordingEvent: Equatable {
    case keyDown
    case keyUp(elapsed: TimeInterval)
    case pillClick
    case esc
    case capReached(generation: Int)
    /// Recording Panel "Done"/"Raw" (Feature 3): unlike `pillClick`, which LOCKS an in-progress
    /// `pttRecording` rather than stopping it, this stops immediately from either recording
    /// state. See PLAN.md step 10.
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

/// Pure push-to-talk / hands-free state machine (Amendment B). No audio, timers, or CGEvents —
/// SelfCheck drives the full transition table directly. See PLAN.md Amendment B6.
enum RecordingStateMachine {
    /// A key-up before this many seconds since key-down is a "tap" (enters `locked`); at or
    /// beyond it is a held push-to-talk (stop on release). See PLAN.md Amendment B1.
    static let tapThreshold: TimeInterval = 0.4

    /// `currentGeneration` is consulted only for `capReached` — every other event ignores it. A
    /// `capReached` whose `generation` doesn't match the live recording's is a stale timer fire
    /// (superseded by a newer recording) and is always a no-op, in any state. See PLAN.md
    /// Amendment B2.
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
