import AppKit
import ApplicationServices

struct AccessibilityAppIdentity: Equatable, Sendable {
    let appName: String?
    let bundleID: String?
    let pid: pid_t

    init(appName: String?, bundleID: String?, pid: pid_t = 0) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
    }
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
    func selectedText(pid: pid_t) -> String?
    func focusedField(pid: pid_t) -> AccessibilityFocusedField?
    func activeWindow(pid: pid_t) -> AccessibilityWindow?
    func activeWindowMetadata(pid: pid_t) -> AccessibilityWindowMetadata?
}

@MainActor
protocol AccessibilityNodeAdapting: AnyObject {
    associatedtype Node
    associatedtype Identity: Hashable

    func identity(of node: Node) -> Identity
    func isSecure(_ node: Node) -> Bool
    func visibleText(of node: Node) -> String?
    func children(of node: Node) -> [Node]
}

@MainActor
struct AccessibilityTreeReader<Adapter: AccessibilityNodeAdapting> {
    static var maxCharacters: Int { 12_000 }
    static var maxNodes: Int { 5_000 }
    static var maxDepth: Int { 64 }

    let adapter: Adapter

    func visibleText(root: Adapter.Node) -> String {
        var result = ""
        var visited: Set<Adapter.Identity> = []
        var stack: [(node: Adapter.Node, depth: Int)] = [(root, 0)]
        var nodesRead = 0

        while let current = stack.popLast(), result.count < Self.maxCharacters, nodesRead < Self.maxNodes {
            guard current.depth <= Self.maxDepth else { continue }
            let identity = adapter.identity(of: current.node)
            guard visited.insert(identity).inserted else { continue }
            nodesRead += 1
            guard !adapter.isSecure(current.node) else { continue }

            if let text = adapter.visibleText(of: current.node), !text.isEmpty {
                if !result.isEmpty { result.append("\n") }
                result.append(contentsOf: text.prefix(Self.maxCharacters - result.count))
            }
            guard result.count < Self.maxCharacters, current.depth < Self.maxDepth, nodesRead < Self.maxNodes else { continue }
            let children = adapter.children(of: current.node)
            stack.append(contentsOf: children.reversed().map { ($0, current.depth + 1) })
        }
        return result
    }
}

@MainActor
final class AccessibilityContext: AccessibilityContextProviding {
    private let adapter = SystemAccessibilityNodeAdapter()

    func frontmostAppIdentity() -> AccessibilityAppIdentity {
        let app = NSWorkspace.shared.frontmostApplication
        return AccessibilityAppIdentity(
            appName: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            pid: app?.processIdentifier ?? 0
        )
    }

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func selectedText(pid: pid_t) -> String? {
        guard let element = adapter.focusedElement(pid: pid), !adapter.isSecure(element) else { return nil }
        return adapter.stringAttribute(kAXSelectedTextAttribute, from: element)
    }

    func focusedField(pid: pid_t) -> AccessibilityFocusedField? {
        guard let element = adapter.focusedElement(pid: pid) else { return nil }
        let secure = adapter.isSecure(element)
        guard secure || adapter.isEditable(element) else { return nil }
        return AccessibilityFocusedField(
            text: secure ? "" : (adapter.stringAttribute(kAXValueAttribute, from: element) ?? ""),
            isSecure: secure
        )
    }

    func activeWindow(pid: pid_t) -> AccessibilityWindow? {
        guard let window = adapter.focusedWindow(pid: pid) else { return nil }
        let reader = AccessibilityTreeReader(adapter: adapter)
        return AccessibilityWindow(
            title: adapter.stringAttribute(kAXTitleAttribute, from: window),
            visibleText: reader.visibleText(root: window)
        )
    }

    func activeWindowMetadata(pid: pid_t) -> AccessibilityWindowMetadata? {
        guard let window = adapter.focusedWindow(pid: pid) else { return nil }
        return AccessibilityWindowMetadata(title: adapter.stringAttribute(kAXTitleAttribute, from: window))
    }
}

struct AXNodeIdentity: Hashable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

@MainActor
final class SystemAccessibilityNodeAdapter: AccessibilityNodeAdapting {
    typealias Node = AXUIElement
    typealias Identity = AXNodeIdentity

    func identity(of node: AXUIElement) -> AXNodeIdentity {
        AXNodeIdentity(element: node)
    }

    func isSecure(_ node: AXUIElement) -> Bool {
        if stringAttribute(kAXRoleAttribute, from: node) == "AXSecureTextField" { return true }
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(node, "AXProtectedContent" as CFString, &value)
        return result == .success && (value as? Bool == true || (value as? NSNumber)?.boolValue == true)
    }

    func visibleText(of node: AXUIElement) -> String? {
        let textRoles: Set<String> = [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole]
        guard let role = stringAttribute(kAXRoleAttribute, from: node), textRoles.contains(role) else { return nil }
        return stringAttribute(kAXValueAttribute, from: node)
    }

    func children(of node: AXUIElement) -> [AXUIElement] {
        elementArrayAttribute(kAXChildrenAttribute, from: node)
    }

    func focusedElement(pid: pid_t) -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute, from: AXUIElementCreateApplication(pid))
    }

    func focusedWindow(pid: pid_t) -> AXUIElement? {
        elementAttribute(kAXFocusedWindowAttribute, from: AXUIElementCreateApplication(pid))
    }

    func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        let editableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        return stringAttribute(kAXRoleAttribute, from: element).map(editableRoles.contains) ?? false
    }

    func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
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
