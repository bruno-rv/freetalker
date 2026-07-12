import Foundation

struct DictationTranslationVariant: Equatable, Sendable {
    var parentID: Int64
    var target: TranslationTarget
    var text: String
    var createdAt: Date
    var updatedAt: Date
}
