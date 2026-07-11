import CoreGraphics
import Vision

protocol VisionOCRServicing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

struct VisionOCRService: VisionOCRServicing, @unchecked Sendable {
    static let maximumCharacters = 12_000

    private let recognizer: @Sendable (CGImage) async throws -> String

    init() {
        recognizer = { image in
            try autoreleasepool {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
                return (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
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
