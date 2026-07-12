import Foundation
import VoiceProfileFluidAudio

do {
    let arguments = try CalibrationArguments.parse(Array(CommandLine.arguments.dropFirst()))
    let data = try Data(contentsOf: arguments.manifestURL, options: [.mappedIfSafe])
    let manifest = try JSONDecoder().decode(CalibrationManifest.self, from: data)
    let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FreeTalker/models/fluidaudio", isDirectory: true)
    let extractor = OfflineSpeakerRepresentationExtractor(modelsDirectory: modelsDirectory)
    let report = try await CalibrationRunner { url in
        try await extractor.process(url) { _ in }
    }.run(manifest: manifest)
    try CalibrationReportWriter.write(report, to: arguments.outputDirectoryURL)
} catch {
    let safeDescription: String
    switch error {
    case let error as CalibrationArgumentError: safeDescription = error.description
    case let error as CalibrationManifestError: safeDescription = error.description
    case let error as CalibrationRunnerError: safeDescription = error.description
    case let error as CalibrationReportWriteError: safeDescription = error.description
    default: safeDescription = "calibration failed"
    }
    FileHandle.standardError.write(Data("error: \(safeDescription)\n".utf8))
    Foundation.exit(EXIT_FAILURE)
}
