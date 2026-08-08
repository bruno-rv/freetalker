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
