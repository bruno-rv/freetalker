import AppKit
import ApplicationServices

struct AccessibilityAppIdentity: Equatable, Sendable {
    let appName: String?
    let bundleID: String?
}

struct AccessibilityFocusedField: Equatable, Sendable {
    let text: String
    let isSecure: Bool
}

struct AccessibilityWindowMetadata: Equatable, Sendable {
    let title: String?
}

struct AccessibilityWindow: Equatable, Sendable {
    let title: String?
    let visibleText: String
}

@MainActor
protocol AccessibilityContextProviding: AnyObject {
    func frontmostAppIdentity() -> AccessibilityAppIdentity
    func isTrusted() -> Bool
    func selectedText() -> String?
    func focusedField() -> AccessibilityFocusedField?
    func activeWindow() -> AccessibilityWindow?
    func activeWindowMetadata() -> AccessibilityWindowMetadata?
}

@MainActor
final class AccessibilityContext: AccessibilityContextProviding {
    func frontmostAppIdentity() -> AccessibilityAppIdentity {
        let app = NSWorkspace.shared.frontmostApplication
        return AccessibilityAppIdentity(appName: app?.localizedName, bundleID: app?.bundleIdentifier)
    }

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func selectedText() -> String? {
        guard let element = focusedElement(), !isSecure(element) else { return nil }
        return stringAttribute(kAXSelectedTextAttribute, from: element)
    }

    func focusedField() -> AccessibilityFocusedField? {
        guard let element = focusedElement() else { return nil }
        let secure = isSecure(element)
        guard secure || isEditable(element) else { return nil }
        return AccessibilityFocusedField(
            text: secure ? "" : (stringAttribute(kAXValueAttribute, from: element) ?? ""),
            isSecure: secure
        )
    }

    func activeWindow() -> AccessibilityWindow? {
        guard let window = focusedWindow() else { return nil }
        return AccessibilityWindow(title: stringAttribute(kAXTitleAttribute, from: window), visibleText: visibleText(in: window))
    }

    func activeWindowMetadata() -> AccessibilityWindowMetadata? {
        guard let window = focusedWindow() else { return nil }
        return AccessibilityWindowMetadata(title: stringAttribute(kAXTitleAttribute, from: window))
    }

    private func focusedElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return elementAttribute(kAXFocusedUIElementAttribute, from: AXUIElementCreateApplication(pid))
    }

    private func focusedWindow() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return elementAttribute(kAXFocusedWindowAttribute, from: AXUIElementCreateApplication(pid))
    }

    private func visibleText(in root: AXUIElement) -> String {
        var result = ""
        appendVisibleText(from: root, to: &result)
        return result
    }

    private func appendVisibleText(from element: AXUIElement, to result: inout String) {
        guard result.count < 12_000, !isSecure(element) else { return }

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let textRoles: Set<String> = [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole]
        if let role, textRoles.contains(role), let text = stringAttribute(kAXValueAttribute, from: element), !text.isEmpty {
            if !result.isEmpty { result.append("\n") }
            result.append(contentsOf: text.prefix(12_000 - result.count))
        }

        for child in elementArrayAttribute(kAXChildrenAttribute, from: element) {
            appendVisibleText(from: child, to: &result)
            if result.count >= 12_000 { break }
        }
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        if stringAttribute(kAXRoleAttribute, from: element) == "AXSecureTextField" { return true }
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &value)
        return result == .success && (value as? Bool == true || (value as? NSNumber)?.boolValue == true)
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        let editableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        return stringAttribute(kAXRoleAttribute, from: element).map(editableRoles.contains) ?? false
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func elementArrayAttribute(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let values = value as? [AnyObject] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }
}
