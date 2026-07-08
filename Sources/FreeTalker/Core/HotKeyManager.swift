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
    var onKeyDown: (@MainActor () -> Void)?
    var onKeyUp: (@MainActor () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher = HotKeyMatcher(spec: .default)

    private static let logger = Logger(subsystem: "com.bruno.freetalker", category: "hotkey")

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
        let kind: KeyEventKind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let outcome = matcher.handle(kind, keyCode: keyCode, flags: event.flags.rawValue, isAutorepeat: isAutorepeat)
        if outcome.engaged {
            Task { @MainActor in self.onKeyDown?() }
        }
        if outcome.released {
            Task { @MainActor in self.onKeyUp?() }
        }
        return outcome.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
