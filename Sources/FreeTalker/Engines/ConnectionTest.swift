import Foundation

enum ConnectionTestOutcome: Equatable {
    case success
    case httpStatus(Int)
    case timedOut
    case unreachable

    /// User-facing result text. The caller (Settings UI) prefixes this with the provider label
    /// (e.g. "Cloud STT: ") — this stays provider-agnostic.
    var message: String {
        switch self {
        case .success:
            return "Connected ✓"
        case .httpStatus(401):
            return "Failed — HTTP 401 (check API key)"
        case .httpStatus(404):
            return "Failed — HTTP 404 (check model/URL)"
        case .httpStatus(let code):
            return "Failed — HTTP \(code)"
        case .timedOut, .unreachable:
            return "Failed — cannot reach host"
        }
    }

    /// Classifies a completed HTTP response's status code. 2xx is success; everything else is
    /// carried through verbatim as `.httpStatus` — `message` is what special-cases 401/404.
    static func fromStatusCode(_ code: Int) -> ConnectionTestOutcome {
        (200...299).contains(code) ? .success : .httpStatus(code)
    }

    /// Classifies a transport-level failure — the request never produced an HTTP response at
    /// all (DNS failure, connection refused, TLS failure, offline, timeout, ...). A timeout gets
    /// its own case only because `URLError` distinguishes it; every other transport failure reads
    /// identically to a user ("can't reach the host") and is collapsed into `.unreachable`.
    static func fromTransportError(_ error: Error) -> ConnectionTestOutcome {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timedOut
        }
        return .unreachable
    }
}
