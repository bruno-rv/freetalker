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
    private static let previewContentionEnvironmentKey = "FREETALKER_PREVIEW_CONTENTION_BENCH"
    private static let modelFolder = NSString(string: "~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo_954MB").expandingTildeInPath
    private static let audioPath = NSString(string: "~/Library/Application Support/FreeTalker/last-dictation.wav").expandingTildeInPath
    private static let vocabulary = [
        "Anh", "Claude", "Conrad", "Joyn", "Data Vault Builder", "DVB", "DBT",
        "Claude Code", "Codex", "Repo", "Grill Me", "Stream Deck", "Qdrant"
    ]

    @Test func loaderDecodesCanonicalFloat32WAV() throws {
        let samples: [Float] = [-0.75, -0.125, 0, 0.375, 0.9]

        #expect(try Self.decodeWAV(Self.float32WAV(samples)) == samples)
    }

    @Test func loaderDecodesLegacyPCM16WAV() throws {
        let encoded = WAVEncoder.encode(samples: [-0.5, 0, 0.5], sampleRate: 16_000)

        #expect(try Self.decodeWAV(encoded) == [-0.49996948, 0, 0.49996948])
    }

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
            let samples = try Self.decodeWAV(data)
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

    /// `WhisperKitEngine.performTranscribe` calls `kit.detectLangauge(audioArray:)` and then
    /// `kit.transcribe(...)`. Both compute a log-mel spectrogram and run the audio encoder over the
    /// first 30 s window, so the encoder runs twice per dictation — WhisperKit's own
    /// `TranscribeTask` instead detects the language *from the encoder output it already has*
    /// (`TranscribeTask.swift`, `decodeWithFallback`). This measures what the separate pass costs
    /// on this machine's real captures, and whether the one-pass alternative picks the same
    /// language (it cannot be constrained to the configured Dictation Language Set, which is why
    /// the separate call exists — see `performTranscribe`).
    ///
    ///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ///       FREETALKER_LANGDETECT_BENCH=1 \
    ///       swift test -c release --filter measureLanguageDetectionCost
    @Test func measureLanguageDetectionCost() async throws {
        guard ProcessInfo.processInfo.environment["FREETALKER_LANGDETECT_BENCH"] != nil else { return }

        let clips = try Self.corpus()
        print("=== langdetect: \(clips.count) distinct clips")

        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: Self.modelFolder, verbose: false, logLevel: .none, load: true, download: false
        ))

        func pinnedOptions(_ language: String?) -> DecodingOptions {
            var options = DecodingOptions()
            options.language = language
            options.usePrefillPrompt = true
            options.detectLanguage = language == nil
            options.temperatureFallbackCount = WhisperKitEngine.decodeFallbackBudget(preview: false)
            return options
        }

        // Warm the CoreML compute plan on both shapes before anything is timed.
        _ = try await kit.detectLangauge(audioArray: clips[0].samples)
        _ = try await kit.transcribe(audioArray: clips[0].samples, decodeOptions: pinnedOptions("en"))
        _ = try await kit.transcribe(audioArray: clips[0].samples, decodeOptions: pinnedOptions(nil))

        var totals = (detect: 0.0, twoPass: 0.0, onePass: 0.0, audio: 0.0)
        var languageDisagreements = 0
        var textDisagreements = 0
        for clip in clips {
            let audioSeconds = Double(clip.samples.count) / 16_000

            let detectStart = Date()
            let (_, langProbs) = try await kit.detectLangauge(audioArray: clip.samples)
            let detectSpan = Date().timeIntervalSince(detectStart)
            let constrained = WhisperKitEngine.constrainedLanguage(langProbs: langProbs, candidates: ["en", "pt"])
            let pinnedStart = Date()
            let pinned = try await kit.transcribe(audioArray: clip.samples, decodeOptions: pinnedOptions(constrained))
            let pinnedSpan = Date().timeIntervalSince(pinnedStart)

            let onePassStart = Date()
            let onePass = try await kit.transcribe(audioArray: clip.samples, decodeOptions: pinnedOptions(nil))
            let onePassSpan = Date().timeIntervalSince(onePassStart)

            let pinnedText = pinned.map(\.text).joined(separator: " ")
            let onePassText = onePass.map(\.text).joined(separator: " ")
            let onePassLanguage = onePass.first?.language ?? "?"
            if onePassLanguage != constrained { languageDisagreements += 1 }
            if pinnedText != onePassText { textDisagreements += 1 }

            totals.detect += detectSpan
            totals.twoPass += detectSpan + pinnedSpan
            totals.onePass += onePassSpan
            totals.audio += audioSeconds

            print("""
            === langdetect clip=\(clip.name) audio=\(Self.format(audioSeconds))s \
            detect=\(Self.format(detectSpan))s pinnedDecode=\(Self.format(pinnedSpan))s \
            twoPass=\(Self.format(detectSpan + pinnedSpan))s onePass=\(Self.format(onePassSpan))s \
            encodeTwoPass=\(Self.format(pinned.first?.timings.encoding ?? 0))s \
            encodeOnePass=\(Self.format(onePass.first?.timings.encoding ?? 0))s \
            language=\(constrained)/\(onePassLanguage) textMatch=\(pinnedText == onePassText)
            """)
            if pinnedText != onePassText {
                print("""
                ===   two-pass: \(pinnedText)
                ===   one-pass: \(onePassText)
                """)
            }
        }

        let saved = totals.twoPass - totals.onePass
        print("""
        === langdetect totals over \(Self.format(totals.audio))s of audio in \(clips.count) clips: \
        detectOnly=\(Self.format(totals.detect))s twoPass=\(Self.format(totals.twoPass))s \
        onePass=\(Self.format(totals.onePass))s saved=\(Self.format(saved))s \
        perClip=\(Self.format(saved / Double(clips.count)))s \
        languageDisagreements=\(languageDisagreements)/\(clips.count) \
        textDisagreements=\(textDisagreements)/\(clips.count)
        """)
    }

    /// Two questions the corpus above cannot answer, because every preserved capture on this
    /// machine is under 30 s:
    ///
    /// 1. Audio longer than one 30 s window is decoded window-by-window in a single
    ///    `TranscribeTask`. WhisperKit's `.vad` chunking instead splits at voice-activity
    ///    boundaries and decodes the chunks *concurrently* (`WhisperKit.transcribe`, the
    ///    `(true, .vad)` case, batched into `concurrentWorkerCount` = 16 on macOS). The app sets
    ///    no strategy, so it always takes the sequential path.
    /// 2. A near-silent capture in the corpus cost 8.5 s to decode 1.8 s of audio — the
    ///    temperature-fallback budget spent in full on audio the quality heuristics keep
    ///    rejecting. This measures what that budget costs on exactly that clip.
    ///
    /// The long-audio input is the corpus concatenated to ~90 s: synthetic, so its transcript is
    /// nonsense, but both variants decode the identical samples so the wall-clock comparison is
    /// honest. Text is printed for both so a chunking-induced difference is visible.
    ///
    ///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ///       FREETALKER_CHUNKING_BENCH=1 \
    ///       swift test -c release --filter measureChunkingAndFallbackCost
    @Test func measureChunkingAndFallbackCost() async throws {
        guard ProcessInfo.processInfo.environment["FREETALKER_CHUNKING_BENCH"] != nil else { return }

        let clips = try Self.corpus()
        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: Self.modelFolder, verbose: false, logLevel: .none, load: true, download: false
        ))

        func options(language: String, chunking: ChunkingStrategy?, fallbacks: Int) -> DecodingOptions {
            var options = DecodingOptions()
            options.language = language
            options.usePrefillPrompt = true
            options.detectLanguage = false
            options.temperatureFallbackCount = fallbacks
            options.chunkingStrategy = chunking
            return options
        }

        // MARK: long audio, sequential windows vs concurrent VAD chunks

        // Bruno's own history (library.db `dictations.duration_secs`, 106 rows) puts 72.6% of all
        // transcribed audio seconds in dictations of 30 s or more, mean 30.6 s, max 299.9 s — so
        // the interesting regime is several windows, not one. Sweep it.
        // Deterministic: the corpus in `corpus()`'s order (filenames sorted, duplicates dropped by
        // content), repeated until the target is covered, then truncated to exactly
        // `seconds * 16_000` samples at 16 kHz mono. The manifest is printed below so a run's
        // numbers can be checked against the input that produced them — the corpus lives outside
        // the repo (`~/Library/Application Support/FreeTalker/failed-dictations`) and grows as
        // dictations fail, so a later run on a different machine is not comparing like with like
        // unless the manifest matches.
        func synthetic(seconds: Int) -> [Float] {
            var samples: [Float] = []
            let target = seconds * 16_000
            while samples.count < target {
                for clip in clips where samples.count < target { samples.append(contentsOf: clip.samples) }
            }
            return Array(samples.prefix(target))
        }

        for clip in clips {
            print("=== chunking corpus clip=\(clip.name) samples=\(clip.samples.count) seconds=\(Self.format(Double(clip.samples.count) / 16_000))")
        }

        _ = try await kit.transcribe(audioArray: synthetic(seconds: 30), decodeOptions: options(language: "en", chunking: nil, fallbacks: 2))
        for seconds in [30, 60, 120, 300] {
            let input = synthetic(seconds: seconds)
            // `.vad` only at the ends of the sweep: if it loses at both one window and twelve,
            // the middle is not where it starts winning. An assumption, not a measurement.
            let strategies: [(String, ChunkingStrategy?)] = seconds == 30 || seconds == 300
                ? [("sequential", nil), ("vad", .vad)]
                : [("sequential", nil)]
            for (label, strategy) in strategies {
                let start = Date()
                let results = try await kit.transcribe(
                    audioArray: input,
                    decodeOptions: options(language: "en", chunking: strategy, fallbacks: WhisperKitEngine.decodeFallbackBudget(preview: false))
                )
                let wall = Date().timeIntervalSince(start)
                // Summed across every result, not read off the first: `.vad` returns one result
                // per voice-activity chunk (15 at 300 s) while sequential returns one, so
                // `results.first?.timings` would report the first chunk's counters as if they
                // were the whole run and make the arms look comparable when they are not.
                let loops = results.reduce(0.0) { $0 + $1.timings.totalDecodingLoops }
                let windows = results.reduce(0.0) { $0 + $1.timings.totalDecodingWindows }
                let fallbacks = results.reduce(0.0) { $0 + $1.timings.totalDecodingFallbacks }
                let text = results.map(\.text).joined(separator: " ")
                print("""
                === chunking audio=\(seconds)s \(label): wall=\(Self.format(wall))s \
                realtimeFactor=\(Self.format(wall / Double(seconds))) results=\(results.count) \
                loops=\(Int(loops)) windows=\(Int(windows)) \
                fallbacks=\(Int(fallbacks)) chars=\(text.count)
                """)
            }
        }

        // MARK: the fallback budget on audio the quality heuristics reject

        guard let shortest = clips.min(by: { $0.samples.count < $1.samples.count }) else { return }
        print("=== fallback: clip=\(shortest.name) audio=\(Self.format(Double(shortest.samples.count) / 16_000))s")
        for budget in [0, 1, 2] {
            let start = Date()
            let results = try await kit.transcribe(
                audioArray: shortest.samples,
                decodeOptions: options(language: "en", chunking: nil, fallbacks: budget)
            )
            let wall = Date().timeIntervalSince(start)
            let timings = results.first?.timings
            print("""
            === fallback budget=\(budget): wall=\(Self.format(wall))s \
            loops=\(Int(timings?.totalDecodingLoops ?? 0)) fallbacks=\(Int(timings?.totalDecodingFallbacks ?? 0)) \
            text=\(results.map(\.text).joined(separator: " "))
            """)
        }
    }

    /// `DecodingFallback.init` (WhisperKit `Models.swift`, "NOTE: order matters here") checks
    /// `isFirstTokenLogProbTooLow` BEFORE the `noSpeechProb > noSpeechThreshold` silence verdict,
    /// so on near-silence the improbable first token wins the race and the decoder retries at a
    /// higher temperature instead of stopping — WhisperKit's own "this is silence" path is
    /// unreachable with the default `firstTokenLogProbThreshold` of -1.5. This measures what
    /// clearing that threshold does to (a) the near-silent clip's decode and (b) the transcripts
    /// of clips that decode fine today, which must not change.
    ///
    ///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ///       FREETALKER_FIRSTTOKEN_BENCH=1 \
    ///       swift test -c release --filter measureFirstTokenThresholdCost
    @Test func measureFirstTokenThresholdCost() async throws {
        guard ProcessInfo.processInfo.environment["FREETALKER_FIRSTTOKEN_BENCH"] != nil else { return }

        let clips = try Self.corpus()
        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: Self.modelFolder, verbose: false, logLevel: .none, load: true, download: false
        ))

        func options(language: String, firstTokenThreshold: Float?) -> DecodingOptions {
            var options = DecodingOptions()
            options.language = language
            options.usePrefillPrompt = true
            options.detectLanguage = false
            options.temperatureFallbackCount = WhisperKitEngine.decodeFallbackBudget(preview: false)
            options.firstTokenLogProbThreshold = firstTokenThreshold
            return options
        }

        _ = try await kit.transcribe(audioArray: clips[0].samples, decodeOptions: options(language: "en", firstTokenThreshold: -1.5))

        var identical = 0
        for clip in clips {
            let (_, langProbs) = try await kit.detectLangauge(audioArray: clip.samples)
            let language = WhisperKitEngine.constrainedLanguage(langProbs: langProbs, candidates: ["en", "pt"])
            var texts: [String] = []
            for (label, threshold) in [("default(-1.5)", Float(-1.5)), ("nil", nil as Float?)] {
                let start = Date()
                let results = try await kit.transcribe(
                    audioArray: clip.samples,
                    decodeOptions: options(language: language, firstTokenThreshold: threshold)
                )
                let wall = Date().timeIntervalSince(start)
                let timings = results.first?.timings
                let text = results.map(\.text).joined(separator: " ")
                texts.append(text)
                print("""
                === firsttoken clip=\(clip.name) audio=\(Self.format(Double(clip.samples.count) / 16_000))s \
                threshold=\(label) wall=\(Self.format(wall))s \
                loops=\(Int(timings?.totalDecodingLoops ?? 0)) fallbacks=\(Int(timings?.totalDecodingFallbacks ?? 0)) \
                chars=\(text.count)
                ===   text: \(text)
                """)
            }
            if texts[0] == texts[1] { identical += 1 }
            else { print("=== firsttoken DIVERGENCE clip=\(clip.name)") }
        }
        print("=== firsttoken totals: identical=\(identical)/\(clips.count)")
    }

    /// Every distinct preserved capture on this machine, deduplicated by content and skipping
    /// anything shorter than a second — shared by the corpus-wide benchmarks.
    private static func corpus() throws -> [(name: String, samples: [Float])] {
        let corpusRoot = NSString(string: "~/Library/Application Support/FreeTalker/failed-dictations").expandingTildeInPath
        var seen = Set<[Float]>()
        var clips: [(name: String, samples: [Float])] = []
        // Every source goes through the same two filters — dedupe on decoded samples, drop
        // anything under a second — so "distinct clips over 1 s" is a property of this function
        // rather than of which directory a clip happened to come from. `last-dictation.wav` is
        // usually a copy of the newest failure, so without the dedupe it doubles one clip's weight
        // in the concatenated sweep.
        func admit(_ name: String, _ samples: [Float]) {
            guard samples.count >= 16_000, seen.insert(samples).inserted else { return }
            clips.append((name, samples))
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: corpusRoot).sorted()
        where name.hasSuffix(".wav") {
            let data = try Data(contentsOf: URL(fileURLWithPath: corpusRoot).appendingPathComponent(name))
            admit(name, try decodeWAV(data))
        }
        if let latest = try? loadPCM(path: audioPath) {
            admit("last-dictation.wav", latest)
        }
        return clips
    }

    /// Measures the stop-time latency the user actually experiences when a live-preview decode is
    /// cancelled immediately before the final request reaches `WhisperKitEngine`'s shared serial
    /// gate, mirroring `AppCoordinator.stopLivePreview()` followed by the final pipeline. This is
    /// deliberately separate from `FREETALKER_DECODE_BENCH`: it runs ten real inference passes and
    /// is only useful on a machine with the pinned model and a real `last-dictation.wav` capture.
    ///
    ///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ///       FREETALKER_PREVIEW_CONTENTION_BENCH=1 \
    ///       swift test --filter measureFinalLatencyWithPreviewContention
    @Test func measureFinalLatencyWithPreviewContention() async throws {
        guard ProcessInfo.processInfo.environment[Self.previewContentionEnvironmentKey] != nil else { return }

        let fileManager = FileManager.default
        _ = try #require(
            fileManager.fileExists(atPath: Self.modelFolder),
            "Pinned Whisper model is required at \(Self.modelFolder)"
        )
        for artifact in SpeechModelStore.requiredArtifacts {
            let path = URL(fileURLWithPath: Self.modelFolder).appendingPathComponent(artifact).path
            _ = try #require(fileManager.fileExists(atPath: path), "Pinned Whisper model is missing \(artifact)")
        }
        _ = try #require(
            fileManager.fileExists(atPath: Self.audioPath),
            "Real-audio fixture is required at \(Self.audioPath)"
        )
        let selectedModel = await AppSettings.shared.whisperModel
        _ = try #require(
            selectedModel == SpeechModelCatalog.defaultID,
            "Benchmark requires selected model \(SpeechModelCatalog.defaultID), found \(selectedModel)"
        )

        let setupStart = Date()
        let allSamples = try Self.loadPCM(path: Self.audioPath)
        let previewSamples = Array(allSamples.suffix(12 * 16_000))
        let audioAttributes = try fileManager.attributesOfItem(atPath: Self.audioPath)
        let audioBytes = audioAttributes[.size] as? NSNumber
        let engine = WhisperKitEngine()
        await engine.preload()
        _ = try #require(engine.isLoaded, "Pinned Whisper model did not load")
        let setupSpan = Date().timeIntervalSince(setupStart)

        let process = ProcessInfo.processInfo
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unknown"
        #endif
        print("""
        === preview-contention metadata: host=\(process.hostName) os=\(process.operatingSystemVersionString) \
        arch=\(architecture) processors=\(process.processorCount) activeProcessors=\(process.activeProcessorCount)
        === preview-contention model: id=\(selectedModel) folder=\(Self.modelFolder)
        === preview-contention audio: path=\(Self.audioPath) bytes=\(audioBytes?.intValue ?? 0) \
        format=WAV/mono/16000Hz samples=\(allSamples.count) finalSeconds=\(Self.seconds(allSamples)) \
        previewSuffixLimit=12.00s previewSeconds=\(Self.seconds(previewSamples))
        === preview-contention setup: model-load+fixture=\(Self.format(setupSpan))s
        """)

        let warmupStart = Date()
        let warmup = try await engine.transcribe(
            samples: allSamples,
            forcedLanguage: nil,
            candidateLanguages: ["en", "pt"],
            vocabulary: []
        )
        let warmupSpan = Date().timeIntervalSince(warmupStart)
        print("""
        === preview-contention warmup: span=\(Self.format(warmupSpan))s chars=\(warmup.text.count) language=\(warmup.language)
        """)

        var idleSamples: [Double] = []
        var contendedSamples: [Double] = []
        for pair in 1...3 {
            // Alternate within-pair order so model/thermal drift is not assigned to one variant.
            if pair.isMultiple(of: 2) {
                contendedSamples.append(try await Self.measureCancelAtStop(
                    pair: pair, engine: engine, finalSamples: allSamples, previewSamples: previewSamples
                ))
                idleSamples.append(try await Self.measureIdle(pair: pair, engine: engine, samples: allSamples))
            } else {
                idleSamples.append(try await Self.measureIdle(pair: pair, engine: engine, samples: allSamples))
                contendedSamples.append(try await Self.measureCancelAtStop(
                    pair: pair, engine: engine, finalSamples: allSamples, previewSamples: previewSamples
                ))
            }
        }

        let idleMedian = Self.median(idleSamples)
        let contendedMedian = Self.median(contendedSamples)
        let delta = contendedMedian - idleMedian
        let ratio = contendedMedian / idleMedian
        let materialThreshold = max(0.25, idleMedian * 0.20)
        let materiallySlower = delta >= materialThreshold
        print("""
        === preview-contention raw idle-request-to-completion: \(Self.formatted(idleSamples))
        === preview-contention raw cancel-at-stop-final-request-to-completion: \(Self.formatted(contendedSamples))
        === preview-contention result: idleMedian=\(Self.format(idleMedian))s \
        contendedMedian=\(Self.format(contendedMedian))s delta=\(Self.format(delta))s ratio=\(String(format: "%.2f", ratio))x
        === preview-contention diagnostic: material means delta >= max(0.25s, 20% of idle)=\(Self.format(materialThreshold))s; \
        observed=\(materiallySlower ? "MATERIAL CONTENTION" : "NO MATERIAL CONTENTION")
        """)
    }

    private static func measureIdle(pair: Int, engine: WhisperKitEngine, samples: [Float]) async throws -> Double {
        let start = Date()
        let output = try await engine.transcribe(
            samples: samples, forcedLanguage: nil, candidateLanguages: ["en", "pt"], vocabulary: []
        )
        let span = Date().timeIntervalSince(start)
        print("=== preview-contention pair=\(pair) idle: request-to-completion=\(format(span))s chars=\(output.text.count)")
        return span
    }

    private static func measureCancelAtStop(
        pair: Int,
        engine: WhisperKitEngine,
        finalSamples: [Float],
        previewSamples: [Float]
    ) async throws -> Double {
        let previewRequest = Date()
        let previewTask = Task {
            do {
                let output = try await engine.transcribe(
                    samples: previewSamples,
                    forcedLanguage: nil,
                    candidateLanguages: ["en", "pt"],
                    vocabulary: [],
                    allowEarlyCancel: true
                )
                return PreviewTaskOutcome.completed(
                    requestToExit: Date().timeIntervalSince(previewRequest), characters: output.text.count
                )
            } catch is CancellationError {
                return PreviewTaskOutcome.cancelled(exit: Date())
            }
        }

        do {
            try await waitUntilPreviewIsTranscribing(engine)
            let cancellationRequest = Date()
            previewTask.cancel()
            let finalRequest = Date()
            let finalOutput = try await engine.transcribe(
                samples: finalSamples,
                forcedLanguage: nil,
                candidateLanguages: ["en", "pt"],
                vocabulary: []
            )
            let finalSpan = Date().timeIntervalSince(finalRequest)
            switch try await previewTask.value {
            case .cancelled(let exit):
                print("""
                === preview-contention pair=\(pair) cancel-at-stop-preview: cancel-to-exit=\(format(exit.timeIntervalSince(cancellationRequest)))s
                === preview-contention pair=\(pair) cancel-at-stop-final: request-to-completion=\(format(finalSpan))s chars=\(finalOutput.text.count)
                """)
            case .completed(let requestToExit, let characters):
                throw PreviewContentionBenchmarkError.previewIgnoredCancellation(
                    requestToExit: requestToExit, characters: characters
                )
            }
            return finalSpan
        } catch {
            previewTask.cancel()
            _ = try? await previewTask.value
            throw error
        }
    }

    /// `Transcribing…` is set after preview language detection and immediately before the decode,
    /// proving the final request is issued while the preview owns the engine's serial gate rather
    /// than relying on a scheduling sleep that might accidentally measure an idle engine.
    private static func waitUntilPreviewIsTranscribing(_ engine: WhisperKitEngine) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let status = await MainActor.run { engine.statusText }
            if status == "Transcribing…" { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PreviewContentionBenchmarkError.previewDidNotReachDecode
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private static func seconds(_ samples: [Float]) -> String {
        format(Double(samples.count) / 16_000)
    }

    private static func formatted(_ samples: [Double]) -> String {
        "[" + samples.map { "\(format($0))s" }.joined(separator: ", ") + "]"
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    /// Decodes the legacy PCM16 artifact and the journal's canonical IEEE Float artifact.
    private static func loadPCM(path: String) throws -> [Float] {
        try decodeWAV(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func decodeWAV(_ data: Data) throws -> [Float] {
        guard data.count >= 12,
              data.ascii(at: 0, count: 4) == "RIFF",
              data.ascii(at: 8, count: 4) == "WAVE",
              let declaredSize = data.uint32(at: 4),
              Int(declaredSize) + 8 <= data.count else {
            throw DecodePromptBenchmarkWAVError.invalidContainer
        }

        let riffEnd = Int(declaredSize) + 8
        var format: (code: UInt16, channels: UInt16, rate: UInt32, blockAlign: UInt16, bits: UInt16)?
        var payload: Range<Int>?
        var offset = 12
        while offset + 8 <= riffEnd {
            guard let chunkSizeValue = data.uint32(at: offset + 4) else {
                throw DecodePromptBenchmarkWAVError.invalidContainer
            }
            let chunkSize = Int(chunkSizeValue)
            let bodyStart = offset + 8
            let (bodyEnd, overflow) = bodyStart.addingReportingOverflow(chunkSize)
            guard !overflow, bodyEnd <= riffEnd else {
                throw DecodePromptBenchmarkWAVError.invalidContainer
            }

            switch data.ascii(at: offset, count: 4) {
            case "fmt ":
                guard chunkSize >= 16,
                      let code = data.uint16(at: bodyStart),
                      let channels = data.uint16(at: bodyStart + 2),
                      let rate = data.uint32(at: bodyStart + 4),
                      let blockAlign = data.uint16(at: bodyStart + 12),
                      let bits = data.uint16(at: bodyStart + 14) else {
                    throw DecodePromptBenchmarkWAVError.invalidContainer
                }
                format = (code, channels, rate, blockAlign, bits)
            case "data":
                payload = bodyStart..<bodyEnd
            default:
                break
            }

            let padding = chunkSize.isMultiple(of: 2) ? 0 : 1
            offset = bodyEnd + padding
        }

        guard let format, let payload,
              format.channels == 1,
              format.rate == 16_000 else {
            throw DecodePromptBenchmarkWAVError.unsupportedFormat
        }
        switch (format.code, format.bits, format.blockAlign) {
        case (1, 16, 2):
            guard payload.count.isMultiple(of: 2) else {
                throw DecodePromptBenchmarkWAVError.invalidContainer
            }
            return stride(from: payload.lowerBound, to: payload.upperBound, by: 2).map {
                Float(Int16(bitPattern: data.uint16(at: $0)!)) / 32768.0
            }
        case (3, 32, 4):
            guard payload.count.isMultiple(of: 4) else {
                throw DecodePromptBenchmarkWAVError.invalidContainer
            }
            return stride(from: payload.lowerBound, to: payload.upperBound, by: 4).map {
                Float(bitPattern: data.uint32(at: $0)!)
            }
        default:
            throw DecodePromptBenchmarkWAVError.unsupportedFormat
        }
    }

    private static func float32WAV(_ samples: [Float]) -> Data {
        let payloadSize = samples.count * MemoryLayout<Float>.size
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendInteger<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendInteger(UInt32(36 + payloadSize))
        appendASCII("WAVEfmt ")
        appendInteger(UInt32(16))
        appendInteger(UInt16(3))
        appendInteger(UInt16(1))
        appendInteger(UInt32(16_000))
        appendInteger(UInt32(64_000))
        appendInteger(UInt16(4))
        appendInteger(UInt16(32))
        appendASCII("data")
        appendInteger(UInt32(payloadSize))
        for sample in samples { appendInteger(sample.bitPattern) }
        return data
    }
}

private enum DecodePromptBenchmarkWAVError: Error {
    case invalidContainer
    case unsupportedFormat
}

private extension Data {
    func ascii(at offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset + count <= self.count else { return nil }
        return String(data: self[offset..<(offset + count)], encoding: .ascii)
    }

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}

private enum PreviewContentionBenchmarkError: Error {
    case previewDidNotReachDecode
    case previewIgnoredCancellation(requestToExit: Double, characters: Int)
}

private enum PreviewTaskOutcome: Sendable {
    case cancelled(exit: Date)
    case completed(requestToExit: Double, characters: Int)
}
