import Foundation
import Testing
@testable import FreeTalker

@Suite("Cloud STT settings")
struct CloudSTTSettingsTests {
    @Test("defaults to OpenAI transcription with whisper-1")
    @MainActor
    func defaults() throws {
        let suite = "CloudSTTSettingsTests.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.cloudSTTProvider == .openAI)
        #expect(settings.cloudSTTModel == "whisper-1")
        #expect(settings.cloudSTTBaseURL == "https://api.openai.com/v1")
    }

    @Test("migrates an existing custom Cloud STT URL without changing it")
    @MainActor
    func migratesLegacyCustomURL() throws {
        let suite = "CloudSTTSettingsTests.migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://localhost:9000/v1", forKey: "cloudSTTBaseURL")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.cloudSTTProvider == .openAICompatible)
        #expect(settings.cloudSTTBaseURL == "http://localhost:9000/v1")
        #expect(settings.cloudSTTModel == "whisper-1")
        #expect(defaults.string(forKey: "cloudSTTProvider") == CloudSTTProviderKind.openAICompatible.rawValue)
        #expect(defaults.string(forKey: "cloudSTTModel") == "whisper-1")
    }

    @Test("provider, model, and endpoint fields survive reload")
    @MainActor
    func persistence() throws {
        let suite = "CloudSTTSettingsTests.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.cloudSTTProvider = .openAICompatible
        settings.cloudSTTModel = "gpt-4o-transcribe"
        settings.cloudSTTBaseURL = "https://stt.example.test/v1"

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.cloudSTTProvider == .openAICompatible)
        #expect(reloaded.cloudSTTModel == "gpt-4o-transcribe")
        #expect(reloaded.cloudSTTBaseURL == "https://stt.example.test/v1")
    }

    @Test("Cloud STT requires provider, model, base URL, and key")
    func configurationRequiresAllFields() {
        #expect(AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "whisper-1", baseURL: "https://api.openai.com/v1", key: "sk-test"))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "", baseURL: "https://api.openai.com/v1", key: "sk-test"))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "   ", baseURL: "https://api.openai.com/v1", key: "sk-test"))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "whisper-1", baseURL: "", key: "sk-test"))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "whisper-1", baseURL: "not-a-url", key: "sk-test"))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "whisper-1", baseURL: "ftp://stt.example.test/v1", key: "sk-test"))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "whisper-1", baseURL: "https://stt.example.test:99999/v1", key: "sk-test"))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "whisper-1", baseURL: "https://stt.example.test:/v1", key: "sk-test"))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "whisper-1", baseURL: "https://api.openai.com/v1", key: ""))
        #expect(!AppCoordinator.isCloudSTTConfigured(provider: .openAI, model: "whisper-1", baseURL: "https://api.openai.com/v1", key: "   "))
    }

    @Test("multipart transcription body uses the configured model")
    func multipartUsesConfiguredModel() throws {
        let body = CloudSTTEngine().multipartBody(
            boundary: "test-boundary",
            wavData: Data(),
            model: "gpt-4o-transcribe",
            vocabulary: [],
            forcedLanguage: nil
        )
        let bodyText = try #require(String(data: body, encoding: .utf8))
        #expect(bodyText.contains("gpt-4o-transcribe"))
        #expect(!bodyText.contains("whisper-1"))
    }

    @Test("legacy Cloud STT key migrates to the selected provider account")
    func migratesLegacyKey() {
        let store = InMemorySecretStore(values: [Keychain.Account.cloudSTTKey: "sk-legacy"])

        CloudSTTKeyMigration.migrateIfNeeded(provider: .openAI, store: store)

        #expect(store.values[Keychain.Account.cloudSTTKey(for: .openAI)] == "sk-legacy")
        #expect(store.values[Keychain.Account.cloudSTTKey] == nil)
    }

    @Test("legacy Cloud STT key is removed when scoped key already exists")
    func removesObsoleteLegacyKeyWhenScopedKeyExists() {
        let scopedAccount = Keychain.Account.cloudSTTKey(for: .openAI)
        let store = InMemorySecretStore(values: [
            scopedAccount: "sk-scoped",
            Keychain.Account.cloudSTTKey: "sk-legacy"
        ])

        CloudSTTKeyMigration.migrateIfNeeded(provider: .openAI, store: store)

        #expect(store.values[scopedAccount] == "sk-scoped")
        #expect(store.values[Keychain.Account.cloudSTTKey] == nil)
    }

    @Test("detects Ollama-shaped base URLs that don't support transcription")
    func detectsKnownNonTranscriptionSTTBaseURL() {
        #expect(CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL("https://ollama.com/v1"))
        #expect(CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL("http://localhost:11434/v1"))
        #expect(CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL("http://192.168.1.20:11434/v1"))
        #expect(CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL("http://mac-mini.local:11434/v1"))
        #expect(!CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL("https://api.openai.com/v1"))
        #expect(!CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL("http://localhost:8080/v1"))
        #expect(!CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL("not-a-url"))
    }

    @Test("clearing a Cloud STT key removes the provider-scoped secret")
    func clearingKeyDeletesSecret() {
        let account = Keychain.Account.cloudSTTKey(for: .openAI)
        let store = InMemorySecretStore(values: [account: "sk-test"])

        #expect(CloudSTTCredentialWriter.update("", account: account, store: store))
        #expect(store.values[account] == nil)
    }

    private final class InMemorySecretStore: SecretStore {
        var values: [String: String]

        init(values: [String: String] = [:]) {
            self.values = values
        }

        func get(account: String) -> String? { values[account] }
        @discardableResult func set(_ value: String, account: String) -> Bool {
            values[account] = value
            return true
        }
        @discardableResult func delete(account: String) -> Bool {
            values.removeValue(forKey: account)
            return true
        }
    }
}
