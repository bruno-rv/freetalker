import CryptoKit
import Foundation

@MainActor
struct SelectionSnapshot {
    let target: InsertionTarget
    let range: NSRange
    let text: String
    let fingerprint: Data

    nonisolated static func fingerprint(for text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }
}
