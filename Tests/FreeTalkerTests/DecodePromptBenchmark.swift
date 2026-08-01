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

    /// Codex adversarial review round 2 asked whether withholding the prompt costs proper-noun
    /// recall, not just formatting. This decodes every preserved capture on this machine twice and
    /// reports which registered terms each transcript contains, so the answer is a count rather
    /// than an opinion.
    ///
    ///     … FREETALKER_DECODE_BENCH=1 swift test --filter measureVocabularyRecallAcrossCorpus
    @Test func measureVocabularyRecallAcrossCorpus() async throws {
        guard ProcessInfo.processInfo.environment["FREETALKER_DECODE_BENCH"] != nil else { return }

        let corpusRoot = NSString(string: "~/Library/Application Support/FreeTalker/failed-dictations").expandingTildeInPath
        var seen = Set<Data>()
        var clips: [(name: String, samples: [Float])] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: corpusRoot).sorted()
        where name.hasSuffix(".wav") {
            let data = try Data(contentsOf: URL(fileURLWithPath: corpusRoot).appendingPathComponent(name))
            guard seen.insert(data).inserted else { continue }
            let samples = Self.decodePCM(data)
            guard samples.count >= 16_000 else { continue }
            clips.append((name, samples))
        }
        // The app rewrites/removes this one; include it when it happens to be there.
        if let latest = try? Self.loadPCM(path: Self.audioPath) {
            clips.append(("last-dictation.wav", latest))
        }
        let seconds = clips.reduce(0.0) { $0 + Double($1.samples.count) / 16_000 }
        print("=== recall: \(clips.count) distinct clips, \(String(format: "%.0f", seconds))s of audio")

        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: Self.modelFolder, verbose: false, logLevel: .none, load: true, download: false
        ))
        let tokenizer = try #require(kit.tokenizer)
        let promptTokens = tokenizer.encode(text: VocabularyFitGate.serializedPrompt(Self.vocabulary))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }

        var hits: [String: (withPrompt: Int, without: Int)] = [:]
        var wall: (withPrompt: Double, without: Double) = (0, 0)
        for clip in clips {
            let (_, langProbs) = try await kit.detectLangauge(audioArray: clip.samples)
            let language = WhisperKitEngine.constrainedLanguage(langProbs: langProbs, candidates: ["en", "pt"])
            var texts: [String: String] = [:]
            for (variant, prompt) in [("with-prompt", promptTokens), ("no-prompt", nil as [Int]?)] {
                var options = DecodingOptions()
                options.language = language
                options.usePrefillPrompt = true
                options.detectLanguage = false
                options.temperatureFallbackCount = WhisperKitEngine.decodeFallbackBudget(preview: false)
                options.promptTokens = prompt
                let start = Date()
                let results = try await kit.transcribe(audioArray: clip.samples, decodeOptions: options)
                let elapsed = Date().timeIntervalSince(start)
                if variant == "with-prompt" { wall.withPrompt += elapsed } else { wall.without += elapsed }
                texts[variant] = results.map(\.text).joined(separator: " ")
                let timings = results.first?.timings
                print("""
                === recall clip=\(clip.name) audio=\(String(format: "%.1f", Double(clip.samples.count) / 16_000))s \
                \(variant) wall=\(String(format: "%.2f", elapsed))s \
                loops=\(Int(timings?.totalDecodingLoops ?? 0)) windows=\(Int(timings?.totalDecodingWindows ?? 0)) \
                promptTokens=\(prompt?.count ?? 0) chars=\(texts[variant]!.count)
                ===   text: \(texts[variant]!)
                """)
            }
            for term in Self.vocabulary {
                let inPrompted = texts["with-prompt"]!.range(of: term, options: .caseInsensitive) != nil
                let inPlain = texts["no-prompt"]!.range(of: term, options: .caseInsensitive) != nil
                if inPrompted || inPlain {
                    var entry = hits[term] ?? (0, 0)
                    entry.withPrompt += inPrompted ? 1 : 0
                    entry.without += inPlain ? 1 : 0
                    hits[term] = entry
                }
                // Only the clips where the two decisions differ are worth reading by hand.
                if inPrompted != inPlain {
                    print("""
                    === recall DIVERGENCE \(clip.name) term=\(term) prompted=\(inPrompted) plain=\(inPlain)
                    ===   with-prompt: \(texts["with-prompt"]!)
                    ===   no-prompt:   \(texts["no-prompt"]!)
                    """)
                }
            }
        }
        for (term, counts) in hits.sorted(by: { $0.key < $1.key }) {
            print("=== recall term=\(term) with-prompt=\(counts.withPrompt) no-prompt=\(counts.without)")
        }
        print("""
        === recall totals: with-prompt=\(String(format: "%.1f", wall.withPrompt))s \
        no-prompt=\(String(format: "%.1f", wall.without))s over \(String(format: "%.0f", seconds))s of audio
        """)
    }

    /// 16 kHz mono PCM16 — the only format `CaptureSegmentCodec` ever writes.
    private static func loadPCM(path: String) throws -> [Float] {
        decodePCM(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func decodePCM(_ data: Data) -> [Float] {
        let body = Data(data.dropFirst(44))
        return body.withUnsafeBytes { raw -> [Float] in
            let ints = raw.bindMemory(to: Int16.self)
            return ints.map { Float($0) / 32768.0 }
        }
    }
}
