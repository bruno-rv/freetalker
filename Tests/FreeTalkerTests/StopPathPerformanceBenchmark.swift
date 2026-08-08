import Foundation
import Testing
@testable import FreeTalker

/// Measures the synchronous debug-artifact work performed by
/// `AppCoordinator.writeLastCaptureDebugArtifact`, comparing the legacy PCM encoding and write
/// with the production canonical-artifact publisher. The benchmark never resolves or writes
/// `FreeTalkerPaths.debugAudio`.
///
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       FREETALKER_STOP_PATH_BENCH=1 \
///       swift test -c release --filter StopPathPerformanceBenchmark
@Suite struct StopPathPerformanceBenchmark {
    private static let environmentKey = "FREETALKER_STOP_PATH_BENCH"
    private static let sampleRate = 16_000
    private static let repetitions = 5

    @Test func measureLegacyAndOptimizedDebugArtifactPublishing() throws {
        guard ProcessInfo.processInfo.environment[Self.environmentKey] != nil else { return }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("freetalker-stop-path-benchmark-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let process = ProcessInfo.processInfo
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unknown"
        #endif
        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif
        print("""
        === stop-path metadata: host=\(process.hostName) os=\(process.operatingSystemVersionString) \
        arch=\(architecture) processors=\(process.processorCount) activeProcessors=\(process.activeProcessorCount) \
        configuration=\(buildConfiguration) sampleRate=\(Self.sampleRate)Hz repetitions=\(Self.repetitions)
        === stop-path temporary-directory: \(temporaryDirectory.path)
        """)

        for duration in [10, 60, 600] {
            let samples = Array(repeating: Float(0.25), count: duration * Self.sampleRate)
            let canonical = temporaryDirectory.appendingPathComponent("canonical-\(duration)s.wav")
            let canonicalData = Self.float32WAV(samples)
            try canonicalData.write(to: canonical)
            let legacyOutput = temporaryDirectory.appendingPathComponent("legacy-\(duration)s.wav")
            let optimizedOutput = temporaryDirectory.appendingPathComponent(
                "optimized-\(duration)s.wav"
            )
            let oldArtifact = Data("old artifact".utf8)

            try Self.seedDestinations(
                [legacyOutput, optimizedOutput],
                with: oldArtifact
            )
            let legacyWarm = try Self.measureLegacy(samples: samples, destination: legacyOutput)
            let optimizedWarm = try Self.measureOptimized(
                source: canonical,
                samples: samples,
                destination: optimizedOutput
            )
            #expect(try Self.temporaryArtifacts(
                for: optimizedOutput,
                in: temporaryDirectory,
                fileManager: fileManager
            ).isEmpty)
            print("""
            === stop-path duration=\(duration)s warmup: legacy=\(Self.format(legacyWarm.combined))s \
            optimized=\(Self.format(optimizedWarm))s
            """)

            var legacyMeasurements: [Measurement] = []
            var optimizedMeasurements: [Double] = []
            for repetition in 1...Self.repetitions {
                try Self.seedDestinations(
                    [legacyOutput, optimizedOutput],
                    with: oldArtifact
                )
                #expect(try Data(contentsOf: legacyOutput) == oldArtifact)
                #expect(try Data(contentsOf: optimizedOutput) == oldArtifact)

                let legacy: Measurement
                let optimized: Double
                if repetition.isMultiple(of: 2) {
                    optimized = try Self.measureOptimized(
                        source: canonical,
                        samples: samples,
                        destination: optimizedOutput
                    )
                    legacy = try Self.measureLegacy(samples: samples, destination: legacyOutput)
                } else {
                    legacy = try Self.measureLegacy(samples: samples, destination: legacyOutput)
                    optimized = try Self.measureOptimized(
                        source: canonical,
                        samples: samples,
                        destination: optimizedOutput
                    )
                }
                legacyMeasurements.append(legacy)
                optimizedMeasurements.append(optimized)
                #expect(legacy.bytes == 44 + samples.count * MemoryLayout<Int16>.size)
                #expect(try Self.fileSize(at: legacyOutput, fileManager: fileManager) == legacy.bytes)
                #expect(try Self.fileSize(at: optimizedOutput, fileManager: fileManager) == canonicalData.count)
                #expect(try Self.temporaryArtifacts(
                    for: optimizedOutput,
                    in: temporaryDirectory,
                    fileManager: fileManager
                ).isEmpty)
            }

            let encode = legacyMeasurements.map(\.encode)
            let write = legacyMeasurements.map(\.write)
            let legacyCombined = legacyMeasurements.map(\.combined)
            let bytes = try #require(legacyMeasurements.first?.bytes)
            let legacyMedian = Self.median(legacyCombined)
            let optimizedMedian = Self.median(optimizedMeasurements)
            let speedup = legacyMedian / optimizedMedian
            let materialThreshold = 0.100
            print("""
            === stop-path duration=\(duration)s samples=\(samples.count) legacyBytes=\(bytes) canonicalBytes=\(canonicalData.count)
            === stop-path duration=\(duration)s raw-encode: \(Self.formatted(encode))
            === stop-path duration=\(duration)s raw-write: \(Self.formatted(write))
            === stop-path duration=\(duration)s raw-legacy-combined: \(Self.formatted(legacyCombined))
            === stop-path duration=\(duration)s raw-optimized-publish: \(Self.formatted(optimizedMeasurements))
            === stop-path duration=\(duration)s medians: encode=\(Self.format(Self.median(encode)))s \
            write=\(Self.format(Self.median(write)))s legacy=\(Self.format(legacyMedian))s \
            optimized=\(Self.format(optimizedMedian))s speedup=\(String(format: "%.1f", speedup))x
            === stop-path duration=\(duration)s diagnostic: material means optimized >= \(Self.format(materialThreshold))s; \
            observed=\(optimizedMedian >= materialThreshold ? "MATERIAL STOP-PATH COST" : "NO MATERIAL STOP-PATH COST")
            """)
        }
    }

    private static func seedDestinations(_ destinations: [URL], with data: Data) throws {
        for destination in destinations { try data.write(to: destination) }
    }

    private static func measureLegacy(samples: [Float], destination: URL) throws -> Measurement {
        let combinedStart = Date()
        let encodeStart = Date()
        let data = WAVEncoder.encode(samples: samples, sampleRate: UInt32(Self.sampleRate))
        let encodeSpan = Date().timeIntervalSince(encodeStart)
        let writeStart = Date()
        try data.write(to: destination)
        let writeSpan = Date().timeIntervalSince(writeStart)
        return Measurement(
            encode: encodeSpan,
            write: writeSpan,
            combined: Date().timeIntervalSince(combinedStart),
            bytes: data.count
        )
    }

    private static func measureOptimized(
        source: URL,
        samples: [Float],
        destination: URL
    ) throws -> Double {
        let start = Date()
        try LastCaptureDebugArtifactWriter.publish(
            durableSource: source,
            samples: samples,
            destination: destination
        )
        return Date().timeIntervalSince(start)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> Int {
        try #require(
            (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        )
    }

    private static func temporaryArtifacts(
        for destination: URL,
        in directory: URL,
        fileManager: FileManager
    ) throws -> [String] {
        let prefix = ".\(destination.lastPathComponent)."
        return try fileManager.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".tmp")
        }
    }

    private static func float32WAV(_ samples: [Float]) -> Data {
        let payloadSize = samples.count * MemoryLayout<Float>.size
        var data = Data(capacity: 44 + payloadSize)
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
        appendInteger(UInt32(Self.sampleRate))
        appendInteger(UInt32(Self.sampleRate * MemoryLayout<Float>.size))
        appendInteger(UInt16(MemoryLayout<Float>.size))
        appendInteger(UInt16(32))
        appendASCII("data")
        appendInteger(UInt32(payloadSize))
        for sample in samples { appendInteger(sample.bitPattern) }
        return data
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private static func formatted(_ samples: [Double]) -> String {
        "[" + samples.map { "\(format($0))s" }.joined(separator: ", ") + "]"
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.4f", seconds)
    }
}

private struct Measurement {
    let encode: Double
    let write: Double
    let combined: Double
    let bytes: Int
}
