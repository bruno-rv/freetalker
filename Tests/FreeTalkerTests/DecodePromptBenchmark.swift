import Foundation
import Testing
import WhisperKit
@testable import FreeTalker

/// SCRATCH — not part of the suite. Measures what a `promptTokens` vocabulary bias actually costs
/// on this machine, against real captured audio, so the decoder-bias change is backed by a
/// before/after rather than by arithmetic.
///
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer FREETALKER_DECODE_BENCH=1 \
///       swift test --filter DecodePromptBenchmark
@Suite struct DecodePromptBenchmark {
    private static let modelFolder = NSString(string: "~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo_954MB").expandingTildeInPath
    private static let audioPath = NSString(string: "~/Library/Application Support/FreeTalker/last-dictation.wav").expandingTildeInPath
    private static let vocabulary = [
        "Anh", "Claude", "Conrad", "Joyn", "Data Vault Builder", "DVB", "DBT",
        "Claude Code", "Codex", "Repo", "Grill Me", "Stream Deck", "Qdrant"
    ]

    @Test func measurePromptTokenCost() async throws {
        guard ProcessInfo.processInfo.environment["FREETALKER_DECODE_BENCH"] != nil else { return }

        let all = try Self.loadPCM(path: Self.audioPath)
        let short = Array(all.prefix(6 * 16_000))
        print("=== bench: \(all.count) samples (\(Double(all.count) / 16_000)s), short slice \(Double(short.count) / 16_000)s")

        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: Self.modelFolder, verbose: false, logLevel: .none, load: true, download: false
        ))
        let tokenizer = try #require(kit.tokenizer)
        let promptTokens = tokenizer.encode(text: VocabularyFitGate.serializedPrompt(Self.vocabulary))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        print("=== bench: vocabulary serializes to \(promptTokens.count) prompt tokens")

        let (_, langProbs) = try await kit.detectLangauge(audioArray: short)
        let language = WhisperKitEngine.constrainedLanguage(langProbs: langProbs, candidates: ["en", "pt"])
        print("=== bench: language=\(language)")

        for (label, samples) in [("short", short), ("full", all)] {
            for (variant, prompt) in [("with-prompt", promptTokens), ("no-prompt", nil as [Int]?)] {
                var options = DecodingOptions()
                options.language = language
                options.usePrefillPrompt = true
                options.detectLanguage = false
                options.temperatureFallbackCount = WhisperKitEngine.decodeFallbackBudget(preview: false)
                options.promptTokens = prompt

                // Discard the first pass of each configuration: it warms the CoreML compute plan.
                _ = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                let start = Date()
                let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                let wall = Date().timeIntervalSince(start)
                let timings = try #require(results.first?.timings)
                print("""
                === bench \(label)/\(variant): wall=\(String(format: "%.2f", wall))s \
                loops=\(Int(timings.totalDecodingLoops)) windows=\(Int(timings.totalDecodingWindows)) \
                fallbacks=\(Int(timings.totalDecodingFallbacks)) \
                encode=\(String(format: "%.2f", timings.encoding))s \
                decodeLoop=\(String(format: "%.2f", timings.decodingLoop))s
                === bench \(label)/\(variant) text: \(results.map(\.text).joined(separator: " "))
                """)
            }
        }
    }

    /// 16 kHz mono PCM16 — the only format `CaptureSegmentCodec` ever writes.
    private static func loadPCM(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let body = data.dropFirst(44)
        return body.withUnsafeBytes { raw -> [Float] in
            let ints = raw.bindMemory(to: Int16.self)
            return ints.map { Float($0) / 32768.0 }
        }
    }
}
