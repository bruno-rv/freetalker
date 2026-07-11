import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import os

@MainActor
final class HotKeyManager {
    /// Fired with the originating `CGEvent`'s timestamp, converted to seconds since boot (see
    /// `handle(type:event:)`) — NOT the wall-clock time the callback happens to run at. Capture-
    /// start latency (the `Task { @MainActor in ... }` hop, or contention on the main run loop)
    /// can otherwise delay when `AppCoordinator` observes a key event well past when it actually
    /// occurred, which would corrupt the tap-vs-hold elapsed-time decision (`keyUp(elapsed:)`) if
    /// it were computed from `Date()` at handler time instead of from these two timestamps.
    var onKeyDown: (@MainActor (TimeInterval) -> Void)?
    var onKeyUp: (@MainActor (TimeInterval) -> Void)?
    /// Fired when Esc is swallowed while recording (Amendment B1) — the pure decision itself is
    /// `shouldSwallowEscape` below.
    var onEscape: (@MainActor () -> Void)?
    var onRedoKeyDown: (@MainActor (TimeInterval) -> Void)?
    /// Runs synchronously inside the event-tap callback, before it returns nil to swallow the
    /// key. Voice-edit target capture must observe the exact focus/selection that owned the
    /// hotkey event rather than a later main-actor turn.
    var onVoiceEditKeyDown: (@MainActor (TimeInterval) -> Void)?

    /// True while a hands-free recording is in progress (ptt or locked) — mirrored synchronously
    /// by `AppCoordinator` on every `recordingState` transition. Both run on the main thread (the
    /// tap's run-loop source is on the main run loop, same as `matcher` below), so a plain var is
    /// safe here despite crossing `AppCoordinator`'s `@MainActor` isolation — reading it must be
    /// synchronous (unlike `onKeyDown`/`onKeyUp`, dispatched via `Task { @MainActor in ... }`)
    /// since the swallow/pass decision has to be made before the tap callback returns.
    var isRecording = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher = HotKeyMatcher(spec: .default)
    private var redoMatcher: HotKeyMatcher?
    private var voiceEditMatcher: HotKeyMatcher?
    /// Key-downs swallowed by an old matcher generation whose physical key-up may arrive after
    /// a settings-driven tap restart. Repeated reconfiguration can accumulate old generations,
    /// so insertion is explicitly capped by `maximumSwallowedKeyUpTombstones`.
    private var swallowedKeyUpTombstones: Set<UInt16> = []
    /// Mirrors `HotKeyMatcher.keyIsSwallowed` for Esc: true between a swallowed Esc keyDown and
    /// its keyUp, so the keyUp is swallowed too even if `isRecording` has already flipped false
    /// by the time it arrives (cancellation is dispatched asynchronously — see `onEscape`).
    private var escapeIsSwallowed = false

    private static let logger = Logger(subsystem: "com.bruno.freetalker", category: "hotkey")

    /// Esc virtual keycode (kVK_Escape).
    nonisolated static let escapeKeyCode: UInt16 = 53

    nonisolated static func eventTapThreadIsValid() -> Bool {
        Thread.isMainThread
    }

    nonisolated static func shouldSwallowEscape(keyCode: UInt16, isRecording: Bool) -> Bool {
        keyCode == escapeKeyCode && isRecording
    }

    /// Combined per-event dispatch outcome for the production two-matcher-on-one-tap scheme (PTT
    /// + optional Redo Last, both fed from the same `CGEventTap`).
    struct DispatchOutcome: Equatable {
        var pttEngaged = false
        var pttReleased = false
        var redoEngaged = false
        var voiceEditEngaged = false
        var swallow = false
    }

    nonisolated static func dispatch(
        kind: KeyEventKind,
        keyCode: UInt16,
        flags: UInt64,
        isAutorepeat: Bool,
        matcher: inout HotKeyMatcher,
        redoMatcher: inout HotKeyMatcher?,
        voiceEditMatcher: inout HotKeyMatcher?
    ) -> DispatchOutcome {
        let outcome = matcher.handle(kind, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        let redoOutcome = redoMatcher?.handle(kind, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        let voiceEditOutcome = voiceEditMatcher?.handle(kind, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat)
        return DispatchOutcome(
            pttEngaged: outcome.engaged,
            pttReleased: outcome.released,
            redoEngaged: redoOutcome?.engaged == true,
            voiceEditEngaged: voiceEditOutcome?.engaged == true,
            swallow: outcome.swallow || redoOutcome?.swallow == true || voiceEditOutcome?.swallow == true
        )
    }

    nonisolated static func resetMatchers(
        matcher: inout HotKeyMatcher,
        redoMatcher: inout HotKeyMatcher?,
        voiceEditMatcher: inout HotKeyMatcher?
    ) {
        matcher = HotKeyMatcher(spec: matcher.spec)
        redoMatcher = redoMatcher.map { HotKeyMatcher(spec: $0.spec) }
        voiceEditMatcher = voiceEditMatcher.map { HotKeyMatcher(spec: $0.spec) }
    }

    nonisolated static func captureSwallowedKeyUpTombstones(
        matcher: HotKeyMatcher,
        redoMatcher: HotKeyMatcher?,
        voiceEditMatcher: HotKeyMatcher?
    ) -> Set<UInt16> {
        Set([
            matcher.swallowedKeyCodeAwaitingKeyUp,
            redoMatcher?.swallowedKeyCodeAwaitingKeyUp,
            voiceEditMatcher?.swallowedKeyCodeAwaitingKeyUp
        ].compactMap { $0 })
    }

    nonisolated static let maximumSwallowedKeyUpTombstones = 8

    nonisolated static func mergeSwallowedKeyUpTombstones(
        _ additions: Set<UInt16>,
        into tombstones: inout Set<UInt16>
    ) {
        tombstones.formUnion(additions)
        while tombstones.count > maximumSwallowedKeyUpTombstones,
              let stale = tombstones.first {
            tombstones.remove(stale)
        }
    }

    enum TombstoneEventOutcome: Equatable {
        case dispatch
        case swallowWithoutDispatch
    }

    nonisolated static func handleSwallowedKeyUpTombstone(
        kind: KeyEventKind,
        keyCode: UInt16,
        isAutorepeat: Bool,
        tombstones: inout Set<UInt16>
    ) -> TombstoneEventOutcome {
        guard tombstones.contains(keyCode) else { return .dispatch }
        switch kind {
        case .keyUp:
            tombstones.remove(keyCode)
            return .swallowWithoutDispatch
        case .keyDown where isAutorepeat:
            return .swallowWithoutDispatch
        case .keyDown:
            tombstones.remove(keyCode)
            return .dispatch
        case .flagsChanged:
            return .dispatch
        }
    }

    @MainActor
    static func deliverVoiceEditIfNeeded(
        outcome: DispatchOutcome,
        eventSeconds: TimeInterval,
        action: (@MainActor (TimeInterval) -> Void)?
    ) {
        guard outcome.voiceEditEngaged else { return }
        action?(eventSeconds)
    }

    /// True while the event tap exists and is enabled. `ensureHotKeyListening()` uses this to
    /// decide whether the tap must be (re)created — a tap the system disabled counts as dead.
    var isListening: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Starts listening for the given PTT spec and optional Redo Last spec, replacing any
    /// existing tap. Both matchers are fed by the one CGEventTap created here — a `redoSpec`
    /// change alone still requires calling this (via `AppCoordinator.restartHotKeyListening`) to
    /// take effect, same as a `spec` change. Returns false if the tap could not be created
    /// (missing Accessibility/Input Monitoring permission — both TCC states are logged for
    /// diagnosis).
    @discardableResult
    func start(spec: HotKeySpec, redoSpec: HotKeySpec?, voiceEditSpec: HotKeySpec? = nil) -> Bool {
        stop()
        matcher = HotKeyMatcher(spec: spec)
        redoMatcher = redoSpec.map { HotKeyMatcher(spec: $0) }
        voiceEditMatcher = voiceEditSpec.map { HotKeyMatcher(spec: $0) }

        let axTrusted = AXIsProcessTrusted()
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Self.logger.log("tap create attempt: hotkey=\(spec.displayLabel, privacy: .public) AXIsProcessTrusted=\(axTrusted, privacy: .public) IOHIDCheckAccess=\(hidAccess.rawValue, privacy: .public)")

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // .defaultTap (active), not .listenOnly: a modifiers+key hotkey must swallow its own
        // keyDown/keyUp (return nil from the callback) so the keystroke never reaches the
        // frontmost app. Active taps are Accessibility-gated, which the app already requires.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                // This tap's run-loop source is installed exclusively on the main run loop
                // below. Assert that contract before entering MainActor isolation synchronously;
                // event swallowing and voice-selection capture cannot be deferred.
                precondition(HotKeyManager.eventTapThreadIsValid(), "HotKeyManager event tap must run on the main thread")
                let eventAddress = UInt(bitPattern: Unmanaged.passUnretained(event).toOpaque())
                let resultAddress: UInt = MainActor.assumeIsolated {
                    let eventPointer = UnsafeMutableRawPointer(bitPattern: eventAddress)!
                    let isolatedEvent = Unmanaged<CGEvent>.fromOpaque(eventPointer).takeUnretainedValue()
                    // The system disables event taps after a timeout or suspicious input (and
                    // across sleep/wake); without re-enabling, push-to-talk would silently die.
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        manager.swallowedKeyUpTombstones.removeAll()
                        if let tap = manager.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        return eventAddress
                    }
                    return manager.handle(type: type, event: isolatedEvent)
                        .map { UInt(bitPattern: $0.toOpaque()) } ?? 0
                }
                guard let resultPointer = UnsafeMutableRawPointer(bitPattern: resultAddress) else { return nil }
                return Unmanaged<CGEvent>.fromOpaque(resultPointer)
            },
            userInfo: refcon
        ) else {
            swallowedKeyUpTombstones.removeAll()
            Self.logger.error("tap create FAILED: AXIsProcessTrusted=\(axTrusted, privacy: .public) IOHIDCheckAccess=\(hidAccess.rawValue, privacy: .public)")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.log("tap create SUCCEEDED: hotkey=\(spec.displayLabel, privacy: .public)")
        return true
    }

    func stop() {
        Self.mergeSwallowedKeyUpTombstones(Self.captureSwallowedKeyUpTombstones(
            matcher: matcher,
            redoMatcher: redoMatcher,
            voiceEditMatcher: voiceEditMatcher
        ), into: &swallowedKeyUpTombstones)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        Self.resetMatchers(matcher: &matcher, redoMatcher: &redoMatcher, voiceEditMatcher: &voiceEditMatcher)
    }

    /// Runs on the main thread (the tap's run-loop source is on the main run loop), so
    /// mutating `matcher` here is not racy.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        // Esc (Amendment B1): checked ahead of the hotkey matcher below since Esc is never the
        // configured hotkey itself. Swallowed only while recording — see `shouldSwallowEscape`.
        if keyCode == Self.escapeKeyCode {
            if type == .keyDown, Self.shouldSwallowEscape(keyCode: keyCode, isRecording: isRecording) {
                escapeIsSwallowed = true
                Task { @MainActor in self.onEscape?() }
                return nil
            } else if type == .keyUp, escapeIsSwallowed {
                escapeIsSwallowed = false
                return nil
            }
        }

        let kind: KeyEventKind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return Unmanaged.passUnretained(event)
        }
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if Self.handleSwallowedKeyUpTombstone(
            kind: kind,
            keyCode: keyCode,
            isAutorepeat: isAutorepeat,
            tombstones: &swallowedKeyUpTombstones
        ) == .swallowWithoutDispatch {
            return nil
        }
        let outcome = Self.dispatch(kind: kind, keyCode: keyCode, flags: event.flags.rawValue, isAutorepeat: isAutorepeat, matcher: &matcher, redoMatcher: &redoMatcher, voiceEditMatcher: &voiceEditMatcher)
        // CGEventTimestamp is nanoseconds since system startup (excluding sleep) — converted to
        // seconds here, at the tap callback, so `AppCoordinator`'s tap-vs-hold elapsed-time
        // calculation is immune to any delay between this event firing and the hop to the
        // `@MainActor` callback actually running. See `onKeyDown`/`onKeyUp` doc comments above.
        let eventSeconds = TimeInterval(event.timestamp) / 1_000_000_000
        if outcome.pttEngaged {
            Task { @MainActor in self.onKeyDown?(eventSeconds) }
        }
        if outcome.pttReleased {
            Task { @MainActor in self.onKeyUp?(eventSeconds) }
        }
        if outcome.redoEngaged {
            Task { @MainActor in self.onRedoKeyDown?(eventSeconds) }
        }
        if outcome.voiceEditEngaged {
            Self.deliverVoiceEditIfNeeded(
                outcome: outcome,
                eventSeconds: eventSeconds,
                action: onVoiceEditKeyDown
            )
        }
        return outcome.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
