import Foundation

/// Applies a Template to a Transcript to produce a Refined Output. See CONTEXT.md: "Post-Processor".
/// Implementations must never throw for "model unavailable" style conditions that the pipeline
/// can recover from by falling back to the raw transcript — see AppleFMProcessor.
protocol PostProcessor: Sendable {
    func process(transcript: String, template: Template) async throws -> String
}
