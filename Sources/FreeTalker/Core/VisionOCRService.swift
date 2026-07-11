import CoreGraphics
import Vision

protocol VisionOCRServicing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

protocol VisionOCRRequestLifecycle: Sendable {
    func makeOperation(for image: CGImage) -> any VisionOCRRequestOperation
}

protocol VisionOCRRequestOperation: AnyObject, Sendable {
    func perform() throws -> String
}

private struct AppleVisionOCRRequestLifecycle: VisionOCRRequestLifecycle {
    func makeOperation(for image: CGImage) -> any VisionOCRRequestOperation {
        AppleVisionOCRRequestOperation(image: image)
    }
}

private final class AppleVisionOCRRequestOperation: VisionOCRRequestOperation, @unchecked Sendable {
    private let request: VNRecognizeTextRequest
    private let handler: VNImageRequestHandler

    init(image: CGImage) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        self.request = request
        handler = VNImageRequestHandler(cgImage: image, options: [:])
    }

    func perform() throws -> String {
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

struct VisionOCRService: VisionOCRServicing, @unchecked Sendable {
    static let maximumCharacters = 12_000

    private let recognizer: @Sendable (CGImage) async throws -> String

    init() {
        self.init(lifecycle: AppleVisionOCRRequestLifecycle())
    }

    init(lifecycle: any VisionOCRRequestLifecycle) {
        recognizer = { image in
            try autoreleasepool {
                var operation: (any VisionOCRRequestOperation)? = lifecycle.makeOperation(for: image)
                defer { operation = nil }
                return try operation!.perform()
            }
        }
    }

    init(recognizer: @escaping @Sendable (CGImage) async throws -> String) {
        self.recognizer = recognizer
    }

    func recognizeText(in image: CGImage) async throws -> String {
        let text = try await recognizer(image)
        return String(text.prefix(Self.maximumCharacters))
    }
}
