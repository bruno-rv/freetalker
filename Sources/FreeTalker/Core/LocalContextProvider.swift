import Foundation

struct LocalProcessingContext: Equatable, Sendable {
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
    let text: String

    init(appName: String?, bundleID: String? = nil, windowTitle: String?, text: String) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.text = text
    }
}

enum ContextCaptureLimitation: Equatable, Sendable {
    case accessibilityPermissionRequired
}

struct ContextCapture: Equatable, Sendable {
    let context: LocalProcessingContext
    let limitation: ContextCaptureLimitation?

    static let empty = ContextCapture(
        context: LocalProcessingContext(appName: nil, windowTitle: nil, text: ""),
        limitation: nil
    )
}

@MainActor
protocol LocalContextProvider {
    func capture(scope: LocalContextScope) -> ContextCapture
}

@MainActor
final class AccessibilityLocalContextProvider: LocalContextProvider {
    private let accessibility: any AccessibilityContextProviding

    init(accessibility: any AccessibilityContextProviding = AccessibilityContext()) {
        self.accessibility = accessibility
    }

    func capture(scope: LocalContextScope) -> ContextCapture {
        guard scope != .off else { return .empty }

        let identity = accessibility.frontmostAppIdentity()
        let base = LocalProcessingContext(
            appName: identity.appName,
            bundleID: identity.bundleID,
            windowTitle: nil,
            text: ""
        )
        guard accessibility.isTrusted() else {
            return ContextCapture(context: base, limitation: .accessibilityPermissionRequired)
        }

        let context: LocalProcessingContext
        switch scope {
        case .off:
            return .empty
        case .selectedText:
            context = with(base, text: bounded(accessibility.selectedText(pid: identity.pid) ?? "", limit: 8_000))
        case .focusedField:
            let field = accessibility.focusedField(pid: identity.pid)
            let text = field?.isSecure == false ? field?.text ?? "" : ""
            context = with(base, text: bounded(text, limit: 8_000))
        case .activeWindow:
            let window = accessibility.activeWindow(pid: identity.pid)
            context = with(base, windowTitle: window?.title, text: bounded(window?.visibleText ?? "", limit: 12_000))
        case .windowOCR:
            let metadata = accessibility.activeWindowMetadata(pid: identity.pid)
            context = with(base, windowTitle: metadata?.title)
        }
        return ContextCapture(context: context, limitation: nil)
    }

    private func bounded(_ text: String, limit: Int) -> String {
        String(text.prefix(limit))
    }

    private func with(
        _ context: LocalProcessingContext,
        windowTitle: String? = nil,
        text: String? = nil
    ) -> LocalProcessingContext {
        LocalProcessingContext(
            appName: context.appName,
            bundleID: context.bundleID,
            windowTitle: windowTitle ?? context.windowTitle,
            text: text ?? context.text
        )
    }
}
