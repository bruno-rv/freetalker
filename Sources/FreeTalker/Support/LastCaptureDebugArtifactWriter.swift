import Darwin
import Foundation

enum LastCaptureDebugArtifactWriter {
    static func publish(
        durableSource: URL?,
        samples: [Float],
        destination: URL
    ) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        if let durableSource {
            do {
                try publishIndependentCopy(
                    of: durableSource,
                    to: temporary,
                    fileManager: fileManager
                )
                try atomicRename(temporary, to: destination)
                return
            } catch {
                try? fileManager.removeItem(at: temporary)
            }
        }

        try WAVEncoder.encode(samples: samples, sampleRate: 16_000).write(to: temporary)
        try atomicRename(temporary, to: destination)
    }

    private static func publishIndependentCopy(
        of source: URL,
        to temporary: URL,
        fileManager: FileManager
    ) throws {
        let cloneResult = source.path.withCString { sourcePath in
            temporary.path.withCString { temporaryPath in
                clonefile(sourcePath, temporaryPath, 0)
            }
        }
        guard cloneResult != 0 else { return }

        let cloneError = errno
        guard cloneError == ENOTSUP || cloneError == EXDEV else {
            throw LastCaptureDebugArtifactWriterError.fileOperation(
                operation: "clone",
                source: source.path,
                destination: temporary.path,
                code: cloneError
            )
        }
        try fileManager.copyItem(at: source, to: temporary)
    }

    private static func atomicRename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw LastCaptureDebugArtifactWriterError.fileOperation(
                operation: "rename",
                source: source.path,
                destination: destination.path,
                code: errno
            )
        }
    }
}

private enum LastCaptureDebugArtifactWriterError: LocalizedError {
    case fileOperation(operation: String, source: String, destination: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .fileOperation(let operation, let source, let destination, let code):
            "Failed to \(operation) \(source) to \(destination): \(String(cString: strerror(code)))"
        }
    }
}
