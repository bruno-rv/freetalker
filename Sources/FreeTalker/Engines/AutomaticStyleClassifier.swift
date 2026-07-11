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
    func classify(bundleID: String?, windowTitle: String?, context: String) -> AutomaticStyle {
        let bundle = bundleID?.lowercased() ?? ""
        let title = windowTitle?.lowercased() ?? ""
        let text = context.lowercased()

        if containsAny(bundle, ["mail", "outlook", "airmail", "spark"]) {
            return .email
        }
        if containsAny(bundle, ["messages", "slack", "discord", "teams", "telegram", "whatsapp", "signal"]) {
            return .conversational
        }
        if containsAny(bundle, ["xcode", "terminal", "iterm", "warp", "visual-studio-code", "github"]) {
            return .technical
        }
        if containsAny(bundle, ["pages", "word", "writer", "notes"]) {
            return .document
        }
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
