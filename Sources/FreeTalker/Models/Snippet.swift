import Foundation

struct Snippet: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var triggers: [String]
    var expansion: String
    let createdAt: Date
    var updatedAt: Date
}

enum SnippetMatch: Equatable, Sendable {
    case none
    case match(Snippet)
    case ambiguous([Snippet])
}

enum SnippetStoreError: Error, Equatable {
    case emptyTrigger
    case duplicateTrigger(String)
    case duplicateName
    case notFound
    case corruptData(String)
}
