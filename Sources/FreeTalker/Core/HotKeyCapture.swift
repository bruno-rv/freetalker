import AppKit

/// One-shot capture of "the next key or combination pressed", used by Settings to let the
/// user pick a different push-to-talk hotkey. Produces a HotKeySpec in the same NX
/// device-mask scheme HotKeyManager matches at runtime.
///
/// Two shapes are captured:
/// - Modifier-only chord: the user holds one or more modifiers and releases them all — the
///   set held at its maximum is captured (e.g. Right ⌥, or ⌃⌥).
/// - Modifiers+key: the user presses a non-modifier key (with any modifiers currently held) —
///   captured immediately, including a bare key like F13. Escape cancels.
enum HotKeyCapture {
    /// Starts transient local monitors and calls `completion` once with the captured spec,
    /// or nil if capture was cancelled (Escape), then stops itself.
    @MainActor
    final class Session {
        private var monitors: [Any] = []
        /// Largest modifier set seen so far in this capture, in device-mask bits.
        private var maxHeldModifiers: UInt64 = 0

        func start(completion: @escaping @MainActor (HotKeySpec?) -> Void) {
            let finish: @MainActor (HotKeySpec?) -> Void = { [weak self] spec in
                self?.cancel()
                completion(spec)
            }

            // A *global* monitor only receives events posted to *other* apps — it never fires
            // for keys pressed while our own Settings window is key, which is exactly the case
            // here. A *local* monitor is what's needed, and (unlike HotKeyManager's CGEventTap)
            // needs no Accessibility/Input Monitoring permission. See root cause B.
            //
            // Reads CGEvent flags rather than NSEvent.modifierFlags so the device-mask bits
            // recorded here are in the same bit domain HotKeyManager checks at runtime —
            // guaranteeing whatever is captured here actually matches during real PTT use.
            if let flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
                guard let self, let raw = event.cgEvent?.flags.rawValue else { return event }
                let held = HotKeySpec.heldDeviceMask(inFlags: raw)
                if held != 0, held.nonzeroBitCount >= self.maxHeldModifiers.nonzeroBitCount {
                    self.maxHeldModifiers = held
                }
                if held == 0, self.maxHeldModifiers != 0 {
                    // All modifiers released without a non-modifier key: a modifier-only chord.
                    let captured = self.maxHeldModifiers
                    Task { @MainActor in finish(HotKeySpec(modifiers: captured, keyCode: nil)) }
                }
                return event
            }) {
                monitors.append(flagsMonitor)
            }

            if let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
                if event.keyCode == 53 { // Escape cancels capture.
                    Task { @MainActor in finish(nil) }
                    return nil
                }
                let raw = event.cgEvent?.flags.rawValue ?? 0
                let spec = HotKeySpec(modifiers: HotKeySpec.heldDeviceMask(inFlags: raw), keyCode: event.keyCode)
                Task { @MainActor in finish(spec) }
                return nil // Swallow the keystroke — it's a hotkey assignment, not input.
            }) {
                monitors.append(keyMonitor)
            }
        }

        func cancel() {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            maxHeldModifiers = 0
        }
    }
}
