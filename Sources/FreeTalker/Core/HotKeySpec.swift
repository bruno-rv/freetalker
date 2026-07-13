import CoreGraphics
import Foundation

/// A configured push-to-talk hotkey: one or more modifier keys, optionally combined with a
/// non-modifier key (e.g. "Right ⌥", "⌃⌥", "⌘⇧D", or a bare "F13").
///
/// `modifiers` is a union of device-dependent NX_DEVICE*KEYMASK bits — the same bit domain
/// CGEvent flags carry at runtime — so left/right distinction is preserved for single-modifier
/// hotkeys exactly as before. Persisted as JSON in UserDefaults (see AppSettings).
struct HotKeySpec: Codable, Equatable {
    /// Union of device-dependent NX_DEVICE*KEYMASK bits (may be multiple for chords).
    var modifiers: UInt64
    /// Virtual keycode of a non-modifier key; nil for a modifier-only hotkey.
    var keyCode: UInt16?

    /// Right ⌥ (NX_DEVICERALTKEYMASK), the app's historical default.
    static let `default` = HotKeySpec(modifiers: 0x40, keyCode: nil)

    struct ModifierUnit {
        let deviceBit: UInt64
        let genericBit: UInt64
        let label: String
        let symbol: String
    }

    /// All modifier keys recognizable by their device-dependent mask bit, in canonical
    /// ⌃⌥⇧⌘ display order.
    static let modifierUnits: [ModifierUnit] = [
        ModifierUnit(deviceBit: 0x0001, genericBit: CGEventFlags.maskControl.rawValue, label: "Left ⌃", symbol: "⌃"),
        ModifierUnit(deviceBit: 0x2000, genericBit: CGEventFlags.maskControl.rawValue, label: "Right ⌃", symbol: "⌃"),
        ModifierUnit(deviceBit: 0x0020, genericBit: CGEventFlags.maskAlternate.rawValue, label: "Left ⌥", symbol: "⌥"),
        ModifierUnit(deviceBit: 0x0040, genericBit: CGEventFlags.maskAlternate.rawValue, label: "Right ⌥", symbol: "⌥"),
        ModifierUnit(deviceBit: 0x0002, genericBit: CGEventFlags.maskShift.rawValue, label: "Left ⇧", symbol: "⇧"),
        ModifierUnit(deviceBit: 0x0004, genericBit: CGEventFlags.maskShift.rawValue, label: "Right ⇧", symbol: "⇧"),
        ModifierUnit(deviceBit: 0x0008, genericBit: CGEventFlags.maskCommand.rawValue, label: "Left ⌘", symbol: "⌘"),
        ModifierUnit(deviceBit: 0x0010, genericBit: CGEventFlags.maskCommand.rawValue, label: "Right ⌘", symbol: "⌘")
    ]

    private static let allGenericBits: UInt64 = CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskCommand.rawValue

    /// Device bits of the modifier keys currently held, derived from raw CGEvent flags. A
    /// device bit only counts when its generic counterpart is also set — guards against
    /// unrelated low bits in the flags word.
    static func heldDeviceMask(inFlags flags: UInt64) -> UInt64 {
        modifierUnits.reduce(0) { held, unit in
            (flags & unit.deviceBit != 0 && flags & unit.genericBit != 0) ? held | unit.deviceBit : held
        }
    }

    /// Side-agnostic ⌃⌥⇧⌘ categories for a device-bit set.
    static func genericMask(forDeviceMask mask: UInt64) -> UInt64 {
        modifierUnits.reduce(0) { mask & $1.deviceBit != 0 ? $0 | $1.genericBit : $0 }
    }

    /// Side-agnostic ⌃⌥⇧⌘ categories currently held in raw CGEvent flags. Fn/Caps Lock and
    /// other bits are deliberately ignored (F-keys carry NX_SECONDARYFNMASK, which must not
    /// break a bare-key hotkey like F13).
    static func genericMask(inFlags flags: UInt64) -> UInt64 {
        flags & allGenericBits
    }

    /// Human-readable form: side-aware for a single modifier ("Right ⌥", as historically),
    /// ⌃⌥⇧⌘ symbols + key name otherwise ("⌃⌥", "⌘⇧D", "F13").
    var displayLabel: String {
        if keyCode == nil, modifiers.nonzeroBitCount == 1,
           let unit = Self.modifierUnits.first(where: { $0.deviceBit == modifiers }) {
            return unit.label
        }
        var symbols = ""
        var seenCategories: UInt64 = 0
        for unit in Self.modifierUnits where modifiers & unit.deviceBit != 0 && seenCategories & unit.genericBit == 0 {
            symbols += unit.symbol
            seenCategories |= unit.genericBit
        }
        if let keyCode {
            symbols += Self.keyName(for: keyCode)
        }
        return symbols.isEmpty ? "None" : symbols
    }

    static func isValidInsertLastDictationSpec(_ spec: HotKeySpec) -> Bool {
        spec.keyCode != nil
    }

    /// True when `a` and `b` are the same chord at runtime: same `keyCode` and the same
    /// side-normalized (⌃⌥⇧⌘) modifier set — not raw struct equality, since e.g. Left ⌃⌥ and
    /// Right ⌃⌥ match identically at runtime (`modifiersExactlyMatch`/`configuredModifiersHeld`
    /// above both compare side-agnostically for chords and modifiers+key).
    static func collides(_ a: HotKeySpec, _ b: HotKeySpec) -> Bool {
        a.keyCode == b.keyCode
            && genericMask(forDeviceMask: a.modifiers) == genericMask(forDeviceMask: b.modifiers)
    }

    /// True when holding `insertLastDictationSpec`'s modifiers alone would already satisfy
    /// `pttSpec`'s engage condition before `insertLastDictationSpec`'s own keyDown ever arrives —
    /// i.e. `pttSpec` is modifier-only and its side-normalized modifier set is a (non-strict)
    /// subset of `insertLastDictationSpec`'s. Example: PTT=⌃⌥, insert=⌃⌥D — holding ⌃⌥ to reach
    /// for D already engages PTT. Checked both directions by the recorders: the Insert Last
    /// Dictation recorder against the bound PTT spec, and re-recording PTT against any bound
    /// Insert Last Dictation spec.
    static func insertLastDictationShadowsHeldPTT(pttSpec: HotKeySpec, insertLastDictationSpec: HotKeySpec) -> Bool {
        guard pttSpec.keyCode == nil, pttSpec.modifiers != 0 else { return false }
        let pttGeneric = genericMask(forDeviceMask: pttSpec.modifiers)
        let insertGeneric = genericMask(forDeviceMask: insertLastDictationSpec.modifiers)
        return insertGeneric & pttGeneric == pttGeneric
    }

    static func validInsertLastDictationSpec(_ candidate: HotKeySpec, pttSpec: HotKeySpec) -> HotKeySpec? {
        guard isValidInsertLastDictationSpec(candidate), !collides(candidate, pttSpec), !insertLastDictationShadowsHeldPTT(pttSpec: pttSpec, insertLastDictationSpec: candidate) else {
            return nil
        }
        return candidate
    }

    static func validActionSpec(_ candidate: HotKeySpec, pttSpec: HotKeySpec, otherActionSpec: HotKeySpec?) -> HotKeySpec? {
        guard isValidInsertLastDictationSpec(candidate),
              !collides(candidate, pttSpec),
              !insertLastDictationShadowsHeldPTT(pttSpec: pttSpec, insertLastDictationSpec: candidate),
              otherActionSpec.map({ !collides(candidate, $0) }) ?? true else { return nil }
        return candidate
    }

    /// ANSI-US virtual keycode names for display. Fallback covers anything unmapped.
    static func keyName(for keyCode: UInt16) -> String {
        Self.keyNames[keyCode] ?? "Key\(keyCode)"
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
}

enum KeyEventKind {
    case flagsChanged
    case keyDown
    case keyUp
}

/// Pure push-to-talk state machine, factored out of HotKeyManager so it is testable without
/// CGEvents. Feed it (event kind, keycode, raw flags, autorepeat) tuples; it reports engage/
/// release transitions and whether the event must be swallowed (returned nil from the tap).
struct HotKeyMatcher {
    struct Outcome: Equatable {
        var engaged = false
        var released = false
        var swallow = false
    }

    let spec: HotKeySpec
    private(set) var isEngaged = false
    /// True between a swallowed keyDown and its keyUp, so the keyUp is swallowed even when the
    /// chord already released via a modifier drop — otherwise the frontmost app would receive
    /// a keyUp with no matching keyDown.
    private var keyIsSwallowed = false

    var swallowedKeyCodeAwaitingKeyUp: UInt16? {
        keyIsSwallowed ? spec.keyCode : nil
    }

    init(spec: HotKeySpec) {
        self.spec = spec
    }

    mutating func handle(_ kind: KeyEventKind, keyCode: UInt16 = 0, flags: UInt64, isAutorepeat: Bool = false) -> Outcome {
        var outcome = Outcome()
        if let specKey = spec.keyCode {
            switch kind {
            case .keyDown where keyCode == specKey:
                if isAutorepeat {
                    // Ignore autorepeat: no transition, but keep swallowing repeats of an
                    // engaged hotkey so they don't type into the frontmost app.
                    outcome.swallow = keyIsSwallowed
                } else if !isEngaged, modifiersExactlyMatch(flags) {
                    isEngaged = true
                    keyIsSwallowed = true
                    outcome.engaged = true
                    outcome.swallow = true
                } else {
                    outcome.swallow = keyIsSwallowed
                }
            case .keyUp where keyCode == specKey:
                outcome.swallow = keyIsSwallowed
                keyIsSwallowed = false
                if isEngaged {
                    isEngaged = false
                    outcome.released = true
                }
            case .flagsChanged:
                if isEngaged, !configuredModifiersHeld(flags) {
                    isEngaged = false
                    outcome.released = true
                }
            default:
                break
            }
        } else if kind == .flagsChanged {
            if !isEngaged, modifiersExactlyMatch(flags) {
                isEngaged = true
                outcome.engaged = true
            } else if isEngaged, !configuredModifiersHeld(flags) {
                isEngaged = false
                outcome.released = true
            }
        }
        return outcome
    }

    /// Engage condition: the held modifier set equals the configured set exactly (never fires
    /// inside a larger combo). Single modifiers match device-level (left/right-specific), as
    /// the app always has.
    private func modifiersExactlyMatch(_ flags: UInt64) -> Bool {
        if spec.keyCode == nil, spec.modifiers.nonzeroBitCount == 1 {
            return HotKeySpec.heldDeviceMask(inFlags: flags) == spec.modifiers
        }
        // ponytail: chords and modifiers+key match side-agnostically (generic ⌃⌥⇧⌘ bits), not
        // per physical left/right key. Upgrade path: compare heldDeviceMask sets instead and
        // capture per-side chords in HotKeyCapture.
        return HotKeySpec.genericMask(inFlags: flags) == HotKeySpec.genericMask(forDeviceMask: spec.modifiers)
    }

    /// Release condition (inverted): all configured modifier bits still held. Extra modifiers
    /// added mid-hold do not release; dropping any configured one does.
    private func configuredModifiersHeld(_ flags: UInt64) -> Bool {
        if spec.keyCode == nil, spec.modifiers.nonzeroBitCount == 1 {
            return HotKeySpec.heldDeviceMask(inFlags: flags) & spec.modifiers == spec.modifiers
        }
        let wanted = HotKeySpec.genericMask(forDeviceMask: spec.modifiers)
        return HotKeySpec.genericMask(inFlags: flags) & wanted == wanted
    }
}
