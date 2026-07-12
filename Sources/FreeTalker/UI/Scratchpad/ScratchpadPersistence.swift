import AppKit
import Foundation

@MainActor
struct ScratchpadPersistence {
    struct LoadResult {
        let text: NSAttributedString
        let warning: String?
    }

    let url: URL

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadResult(text: NSAttributedString(), warning: nil)
        }

        do {
            let data = try Data(contentsOf: url)
            let text = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            return LoadResult(text: text, warning: nil)
        } catch {
            return LoadResult(
                text: NSAttributedString(),
                warning: "The scratchpad could not be opened. Its original file has been preserved."
            )
        }
    }

    func save(_ text: NSAttributedString) throws {
        let range = NSRange(location: 0, length: (text.string as NSString).length)
        let data = try text.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporaryURL, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
