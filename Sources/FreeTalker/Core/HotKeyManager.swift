import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import os

/// Global push-to-talk key listener via CGEventTap. Requires Accessibility (and Input
/// Monitoring) permission — see Permissions.swift.
///
/// Supports modifier-only hotkeys (single key or chord, e.g. Right ⌥ or ⌃⌥) and
/// modifiers+key combos (e.g. ⌘⇧D, or a bare F13). Matching lives in HotKeyMatcher
/// (HotKeySpec.swift), a pure state machine exercised by SelfCheck.
final class HotKeyManager: @unchecked Sendable {
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
    /// Mirrors `HotKeyMatcher.keyIsSwallowed` for Esc: true between a swallowed Esc keyDown and
    /// its keyUp, so the keyUp is swallowed too even if `isRecording` has already flipped false
    /// by the time it arrives (cancellation is dispatched asynchronously — see `onEscape`).
    private var escapeIsSwallowed = false

    private static let logger = Logger(subsystem: "org.freetalker.app", category: "hotkey")

    /// Esc virtual keycode (kVK_Escape).
    static let escapeKeyCode: UInt16 = 53

    /// Pure swallow/pass decision for Esc (Amendment B1): swallowed only while a hands-free
    /// recording is in progress; idle passes it through untouched. SelfCheck drives this
    /// directly.
    nonisolated static func shouldSwallowEscape(keyCode: UInt16, isRecording: Bool) -> Bool {
        keyCode == escapeKeyCode && isRecording
    }

    /// True while the event tap exists and is enabled. `ensureHotKeyListening()` uses this to
    /// decide whether the tap must be (re)created — a tap the system disabled counts as dead.
    var isListening: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Starts listening for the given hotkey spec, replacing any existing tap.
    /// Returns false if the tap could not be created (missing Accessibility/Input Monitoring
    /// permission — both TCC states are logged for diagnosis).
    @discardableResult
    func start(spec: HotKeySpec) -> Bool {
        stop()
        matcher = HotKeyMatcher(spec: spec)

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
                // The system disables event taps after a timeout or suspicious input (and
                // across sleep/wake); without re-enabling, push-to-talk would silently die
                // after working fine initially.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                return manager.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
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
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
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
        let outcome = matcher.handle(kind, keyCode: keyCode, flags: event.flags.rawValue, isAutorepeat: isAutorepeat)
        // CGEventTimestamp is nanoseconds since system startup (excluding sleep) — converted to
        // seconds here, at the tap callback, so `AppCoordinator`'s tap-vs-hold elapsed-time
        // calculation is immune to any delay between this event firing and the hop to the
        // `@MainActor` callback actually running. See `onKeyDown`/`onKeyUp` doc comments above.
        let eventSeconds = TimeInterval(event.timestamp) / 1_000_000_000
        if outcome.engaged {
            Task { @MainActor in self.onKeyDown?(eventSeconds) }
        }
        if outcome.released {
            Task { @MainActor in self.onKeyUp?(eventSeconds) }
        }
        return outcome.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
