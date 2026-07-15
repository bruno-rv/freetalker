import Foundation

struct RecoveryReconciliationFailure: Sendable, Equatable {
    let artifact: URL
    let message: String
}

struct RecoveryReconciliationReport: Sendable, Equatable {
    var imported = 0
    var duplicates = 0
    var quarantined = 0
    var failed = 0
    var failures: [RecoveryReconciliationFailure] = []
    var storeFailure: String?

    mutating func recordFailure(_ artifact: URL, _ error: Error) {
        failed += 1
        failures.append(.init(artifact: artifact, message: error.localizedDescription))
    }
}
