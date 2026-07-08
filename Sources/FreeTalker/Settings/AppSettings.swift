import Foundation

enum STTEngineKind: String, CaseIterable, Codable {
    case whisperKit
    case cloud
}

enum LLMProviderKind: String, CaseIterable, Codable {
    case anthropic
    case openAICompatible
}

/// Persisted, non-secret app settings. Backed by UserDefaults (simplest storage that fits;
/// see ponytail rung 2/3 — no need for a settings file or DB table for a handful of scalars).
/// Secrets (API keys) never live here — see Keychain.swift.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// The push-to-talk hotkey: modifier chord and/or non-modifier key. Persisted as JSON;
    /// legacy single-modifier installs (pre-HotKeySpec `hotKeyDeviceMask`) are migrated in
    /// `init` so an existing assignment keeps working.
    @Published var hotKeySpec: HotKeySpec {
        didSet {
            if let data = try? JSONEncoder().encode(hotKeySpec) {
                defaults.set(data, forKey: Keys.hotKeySpec)
            }
        }
    }

    @Published var sttEngine: STTEngineKind {
        didSet { defaults.set(sttEngine.rawValue, forKey: Keys.sttEngine) }
    }
    @Published var cloudSTTBaseURL: String {
        didSet { defaults.set(cloudSTTBaseURL, forKey: Keys.cloudSTTBaseURL) }
    }

    @Published var llmProvider: LLMProviderKind {
        didSet { defaults.set(llmProvider.rawValue, forKey: Keys.llmProvider) }
    }
    @Published var cloudLLMBaseURL: String {
        didSet { defaults.set(cloudLLMBaseURL, forKey: Keys.cloudLLMBaseURL) }
    }
    @Published var cloudLLMModel: String {
        didSet { defaults.set(cloudLLMModel, forKey: Keys.cloudLLMModel) }
    }

    @Published var activeTemplateID: String {
        didSet { defaults.set(activeTemplateID, forKey: Keys.activeTemplateID) }
    }

    /// CoreAudio UID of the input device to capture from. nil means "System default" — the
    /// UID (not AudioDeviceID) is persisted since device ids can change across reboots.
    @Published var microphoneDeviceUID: String? {
        didSet { defaults.set(microphoneDeviceUID, forKey: Keys.microphoneDeviceUID) }
    }

    private enum Keys {
        static let hotKeySpec = "hotKeySpec"
        /// Legacy (read-only, for migration): single-modifier NX device mask bit.
        static let legacyHotKeyDeviceMask = "hotKeyDeviceMask"
        static let sttEngine = "sttEngine"
        static let cloudSTTBaseURL = "cloudSTTBaseURL"
        static let llmProvider = "llmProvider"
        static let cloudLLMBaseURL = "cloudLLMBaseURL"
        static let cloudLLMModel = "cloudLLMModel"
        static let activeTemplateID = "activeTemplateID"
        static let microphoneDeviceUID = "microphoneDeviceUID"
    }

    private init() {
        if let data = defaults.data(forKey: Keys.hotKeySpec),
           let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) {
            hotKeySpec = spec
        } else if let legacyMask = defaults.object(forKey: Keys.legacyHotKeyDeviceMask) as? Int64, legacyMask != 0 {
            // Migrate a pre-HotKeySpec single-modifier assignment (e.g. "Left ⌃").
            hotKeySpec = HotKeySpec(modifiers: UInt64(bitPattern: legacyMask), keyCode: nil)
        } else {
            hotKeySpec = .default
        }
        sttEngine = STTEngineKind(rawValue: defaults.string(forKey: Keys.sttEngine) ?? "") ?? .whisperKit
        cloudSTTBaseURL = defaults.string(forKey: Keys.cloudSTTBaseURL) ?? "https://api.openai.com/v1"
        llmProvider = LLMProviderKind(rawValue: defaults.string(forKey: Keys.llmProvider) ?? "") ?? .anthropic
        cloudLLMBaseURL = defaults.string(forKey: Keys.cloudLLMBaseURL) ?? "https://api.anthropic.com/v1"
        cloudLLMModel = defaults.string(forKey: Keys.cloudLLMModel) ?? "claude-sonnet-4-5"
        activeTemplateID = defaults.string(forKey: Keys.activeTemplateID) ?? Template.defaultID
        microphoneDeviceUID = defaults.string(forKey: Keys.microphoneDeviceUID)
    }
}
