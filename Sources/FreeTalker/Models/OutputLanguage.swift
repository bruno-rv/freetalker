enum OutputLanguage: String, CaseIterable, Codable, Sendable {
    case sameAsSpoken = "same"
    case english = "en"
    case portuguese = "pt"
    case mandarinChinese = "zh-Hans"
    case hindi = "hi"
    case spanish = "es"
    case standardArabic = "ar"
    case french = "fr"
    case german = "de"

    static func persisted(rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .sameAsSpoken
    }

    var displayName: String {
        switch self {
        case .sameAsSpoken: "Same as spoken"
        case .english: "English"
        case .portuguese: "Portuguese"
        case .mandarinChinese: "Mandarin Chinese"
        case .hindi: "Hindi"
        case .spanish: "Spanish"
        case .standardArabic: "Standard Arabic"
        case .french: "French"
        case .german: "German"
        }
    }

    var promptName: String {
        switch processingPolicy {
        case .preserveSource: "the same language as the source"
        case .translate(let target): target.promptName
        }
    }

    var processingPolicy: OutputProcessingPolicy {
        guard let target = TranslationTarget(rawValue: rawValue) else {
            return .preserveSource
        }
        return .translate(to: target)
    }
}

enum TranslationTarget: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case portuguese = "pt"
    case mandarinChinese = "zh-Hans"
    case hindi = "hi"
    case spanish = "es"
    case standardArabic = "ar"
    case french = "fr"
    case german = "de"

    var promptName: String {
        switch self {
        case .english: "English"
        case .portuguese: "Portuguese"
        case .mandarinChinese: "Mandarin Chinese"
        case .hindi: "Hindi"
        case .spanish: "Spanish"
        case .standardArabic: "Standard Arabic"
        case .french: "French"
        case .german: "German"
        }
    }
}

enum OutputProcessingPolicy: Equatable, Sendable {
    case preserveSource
    case translate(to: TranslationTarget)
}
