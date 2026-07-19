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

struct Dictation: Identifiable, Equatable, Sendable {
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
    /// Destination app bundle id known at dictation STOP time (the stop-time context snapshot),
    /// not paste time. NULL for rows created before this column existed or where no external
    /// destination applies (scratchpad, recovery). See PLAN.md F4.2.
    var bundleID: String? = nil
    /// Captured audio length in seconds — Σ committed capture-segment sample counts ÷ sample rate,
    /// carried as a value from the processing context. NULL where capture metadata never existed.
    var durationSecs: Double? = nil
    /// Whether the `VoiceCommandPolicy` was `.enabled` for this dictation's post-processing pass
    /// (PLAN.md PR A, item 1b). `NULL` means "legacy/unknown" — built-in templates historically
    /// embedded spoken-command conventions directly, so a row predating this column (or written
    /// through a path that doesn't know its own policy) is treated as POSSIBLY command-processed
    /// and excluded from PR B's vocabulary mining, never assumed `false`.
    var voiceCommandsActive: Bool? = nil

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
    var bundleID: String?
    var durationSecs: Double?
    var voiceCommandsActive: Bool?

    init(
        timestamp: Date,
        sourceLanguage: SourceLanguage,
        requestedOutputLanguage: OutputLanguage,
        template: String,
        transcript: String,
        refined: String,
        engine: String,
        sourceID: Int64? = nil,
        bundleID: String? = nil,
        durationSecs: Double? = nil,
        voiceCommandsActive: Bool? = nil
    ) {
        self.timestamp = timestamp
        self.sourceLanguage = sourceLanguage
        self.requestedOutputLanguage = requestedOutputLanguage
        self.template = template
        self.transcript = transcript
        self.refined = refined
        self.engine = engine
        self.sourceID = sourceID
        self.bundleID = bundleID
        self.durationSecs = durationSecs
        self.voiceCommandsActive = voiceCommandsActive
    }
}
