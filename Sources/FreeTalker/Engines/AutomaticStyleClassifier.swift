import Foundation

enum AutomaticStyle: String, CaseIterable, Sendable {
    case email
    case conversational
    case document
    case technical

    var templateID: String {
        switch self {
        case .email: "email"
        case .conversational: "refined-message"
        case .document: "clean-dictation"
        case .technical: "refined-prompt"
        }
    }
}

struct AutomaticStyleClassifier: Sendable {
    private static let emailBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.outlook",
        "com.readdle.smartemail-macos"
    ]
    private static let conversationalBundleIDs: Set<String> = [
        "com.apple.mobilesms",
        "com.tinyspeck.slackmacgap",
        "com.hnc.discord",
        "com.microsoft.teams2",
        "ru.keepcoder.telegram",
        "net.whatsapp.whatsapp",
        "org.whispersystems.signal-desktop"
    ]
    private static let technicalBundleIDs: Set<String> = [
        "com.apple.dt.xcode",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "com.microsoft.vscode",
        "com.github.githubclient"
    ]
    private static let documentBundleIDs: Set<String> = [
        "com.apple.iwork.pages",
        "com.microsoft.word",
        "org.libreoffice.script",
        "com.apple.notes"
    ]

    func classify(bundleID: String?, windowTitle: String?, context: String) -> AutomaticStyle {
        let bundle = bundleID?.lowercased() ?? ""
        let title = windowTitle?.lowercased() ?? ""
        let text = context.lowercased()

        if Self.emailBundleIDs.contains(bundle) { return .email }
        if Self.conversationalBundleIDs.contains(bundle) { return .conversational }
        if Self.technicalBundleIDs.contains(bundle) { return .technical }
        if Self.documentBundleIDs.contains(bundle) { return .document }
        if containsAny(title, [".swift", ".js", ".ts", ".py", ".rs", "terminal", "console"]) ||
            containsAny(text, ["func ", "class ", "struct ", "async throws", "import ", "git "]) {
            return .technical
        }
        if containsAny(title, ["compose", "reply", "inbox"]) { return .email }
        return .document
    }

    func resolveTemplate(
        bundleID: String?,
        windowTitle: String?,
        context: String,
        rules: [String: String],
        templates: [Template],
        activeTemplateID: String
    ) -> Template {
        if let bundleID,
           let ruleTemplateID = rules[bundleID],
           let manual = templates.first(where: { $0.id == ruleTemplateID }) {
            return manual
        }
        let style = classify(bundleID: bundleID, windowTitle: windowTitle, context: context)
        return templates.first(where: { $0.id == style.templateID })
            ?? templates.first(where: { $0.id == activeTemplateID })
            ?? Template.builtIns[0]
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }
}
