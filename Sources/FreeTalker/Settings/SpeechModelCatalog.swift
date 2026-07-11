import Foundation

struct SpeechModelCatalogEntry: Equatable, Sendable {
    let id: String
    let displayName: String
    let approximateSize: String
    let quickTip: String
    let isMultilingual: Bool
}

/// Curated multilingual Whisper variants. English-only `.en` and `distil-*` models are omitted
/// so English and Portuguese dictations are both supported. Large-v2 is deliberately omitted:
/// large-v3 supersedes it in the same size class.
enum SpeechModelCatalog {
    static let defaultID = "openai_whisper-large-v3_turbo_954MB"

    /// Settings display order, from the smallest/fastest model to the current static default.
    static let entries: [SpeechModelCatalogEntry] = [
        .init(
            id: "openai_whisper-tiny", displayName: "Whisper Tiny", approximateSize: "~150 MB",
            quickTip: "Fastest and lightest, with the largest accuracy tradeoff. Best for quick notes on resource-constrained Macs. ID: openai_whisper-tiny",
            isMultilingual: true
        ),
        .init(
            id: "openai_whisper-base", displayName: "Whisper Base", approximateSize: "~290 MB",
            quickTip: "Very fast and compact, with better accuracy than Tiny. Best for everyday short dictation. ID: openai_whisper-base",
            isMultilingual: true
        ),
        .init(
            id: "openai_whisper-small", displayName: "Whisper Small", approximateSize: "~580 MB",
            quickTip: "Fast with solid accuracy and moderate resource use. Best for frequent general-purpose dictation. ID: openai_whisper-small",
            isMultilingual: true
        ),
        .init(
            id: "openai_whisper-medium", displayName: "Whisper Medium", approximateSize: "~1.5 GB",
            quickTip: "Higher accuracy with slower transcription and the heaviest storage use here. Best for difficult audio. ID: openai_whisper-medium",
            isMultilingual: true
        ),
        .init(
            id: "openai_whisper-large-v3_947MB", displayName: "Whisper Large v3", approximateSize: "~947 MB",
            quickTip: "Highest accuracy, with slower transcription and substantial resource use. Best when transcript quality matters most. ID: openai_whisper-large-v3_947MB",
            isMultilingual: true
        ),
        .init(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            displayName: "Whisper Large v3 Turbo (632 MB)", approximateSize: "~632 MB",
            quickTip: "Compact Turbo balances strong accuracy with lower storage and faster loading. Best for capable everyday dictation. ID: openai_whisper-large-v3-v20240930_turbo_632MB",
            isMultilingual: true
        ),
        .init(
            id: defaultID, displayName: "Whisper Large v3 Turbo", approximateSize: "~954 MB",
            quickTip: "Full-size Turbo combines high accuracy with faster decoding than Large v3. Best as the quality-focused default. ID: openai_whisper-large-v3_turbo_954MB",
            isMultilingual: true
        ),
    ]

    /// Device-default preference order, best choice first.
    static let preferenceOrder: [String] = [
        defaultID,
        "openai_whisper-large-v3-v20240930_turbo_632MB",
        "openai_whisper-large-v3_947MB",
        "openai_whisper-medium",
        "openai_whisper-small",
        "openai_whisper-base",
        "openai_whisper-tiny",
    ]

    static func entry(for value: String) -> SpeechModelCatalogEntry? {
        guard let id = catalogID(for: value) else { return nil }
        return entries.first { $0.id == id }
    }

    static func normalize(_ value: String) -> String {
        catalogID(for: value) ?? defaultID
    }

    static func bestSupported<S: Sequence>(in supportedValues: S) -> String where S.Element == String {
        let supported = Set(supportedValues.compactMap(catalogID(for:)))
        return preferenceOrder.first(where: supported.contains) ?? defaultID
    }

    private static func catalogID(for value: String) -> String? {
        if entries.contains(where: { $0.id == value }) { return value }
        let prefixed = "openai_whisper-" + value
        return entries.contains(where: { $0.id == prefixed }) ? prefixed : nil
    }
}
