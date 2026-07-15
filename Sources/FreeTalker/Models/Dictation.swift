import Foundation

struct SourceLanguage: RawRepresentable, Equatable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct Dictation: Identifiable, Equatable {
    var id: Int64
    var timestamp: Date
    var sourceLanguage: SourceLanguage
    var requestedOutputLanguage: OutputLanguage
    var templateName: String
    var transcript: String
    var refined: String
    var engine: String
    var sourceID: Int64?
    var captureID: UUID? = nil

    var language: String {
        get { sourceLanguage.rawValue }
        set { sourceLanguage = SourceLanguage(newValue) }
    }
}

struct DictationInsertRequest: Equatable, Sendable {
    var timestamp: Date
    var sourceLanguage: SourceLanguage
    var requestedOutputLanguage: OutputLanguage
    var template: String
    var transcript: String
    var refined: String
    var engine: String
    var sourceID: Int64?

    init(
        timestamp: Date,
        sourceLanguage: SourceLanguage,
        requestedOutputLanguage: OutputLanguage,
        template: String,
        transcript: String,
        refined: String,
        engine: String,
        sourceID: Int64? = nil
    ) {
        self.timestamp = timestamp
        self.sourceLanguage = sourceLanguage
        self.requestedOutputLanguage = requestedOutputLanguage
        self.template = template
        self.transcript = transcript
        self.refined = refined
        self.engine = engine
        self.sourceID = sourceID
    }
}
