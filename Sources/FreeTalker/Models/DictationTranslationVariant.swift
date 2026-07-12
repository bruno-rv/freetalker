import Foundation

struct DictationTranslationVariant: Equatable, Sendable {
    var parentID: Int64
    var target: TranslationTarget
    var text: String
    var createdAt: Date
    var updatedAt: Date
}

enum TranslationVariantExpectation: Equatable, Sendable {
    case absent
    case version(Date)
}

enum TranslationVariantWriteResult: Equatable, Sendable {
    case committed(DictationTranslationVariant)
    case replacementConfirmationRequired(DictationTranslationVariant)
    case replacementStateChangedToAbsent
}
