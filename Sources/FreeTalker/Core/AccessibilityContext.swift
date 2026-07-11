import AppKit
import ApplicationServices

struct AccessibilityFocusedField: Equatable, Sendable {
    let text: String
    let isSecure: Bool
}

struct AccessibilityWindowMetadata: Equatable, Sendable {
    let windowID: CGWindowID?
    let title: String?

    init(windowID: CGWindowID? = nil, title: String?) {
        self.windowID = windowID
        self.title = title
    }
}

struct AccessibilityWindow: Equatable, Sendable {
    let title: String?
    let visibleText: String
}

@MainActor
protocol AccessibilityContextProviding: ContextTargetAccessibilityProviding {
    func isTrusted() -> Bool
    func selectedText(pid: pid_t) -> String?
    func focusedField(pid: pid_t) -> AccessibilityFocusedField?
    func activeWindow(pid: pid_t) -> AccessibilityWindow?
}

@MainActor
protocol AccessibilityNodeAdapting: AnyObject {
    associatedtype Node
    associatedtype Identity: Hashable

    func identity(of node: Node) -> Identity
    func isSecure(_ node: Node) -> Bool
    func visibleText(of node: Node) -> String?
    func children(of node: Node, maxCount: Int) -> [Node]
}

@MainActor
struct AccessibilityTreeReader<Adapter: AccessibilityNodeAdapting> {
    static var maxCharacters: Int { 12_000 }
    static var maxNodes: Int { 5_000 }
    static var maxDepth: Int { 64 }

    let adapter: Adapter

    func visibleText(root: Adapter.Node) -> String {
        var result = ""
        var scheduled: Set<Adapter.Identity> = [adapter.identity(of: root)]
        var stack: [(node: Adapter.Node, depth: Int)] = [(root, 0)]
        var nodesRead = 0

        while let current = stack.popLast(), result.count < Self.maxCharacters, nodesRead < Self.maxNodes {
            guard current.depth <= Self.maxDepth else { continue }
            nodesRead += 1
            guard !adapter.isSecure(current.node) else { continue }

            if let text = adapter.visibleText(of: current.node), !text.isEmpty {
                if !result.isEmpty { result.append("\n") }
                result.append(contentsOf: text.prefix(Self.maxCharacters - result.count))
            }
            let remainingNodeBudget = Self.maxNodes - scheduled.count
            guard result.count < Self.maxCharacters, current.depth < Self.maxDepth, remainingNodeBudget > 0 else { continue }
            let children = adapter.children(of: current.node, maxCount: remainingNodeBudget)
            var newChildren: [Adapter.Node] = []
            newChildren.reserveCapacity(min(children.count, remainingNodeBudget))
            for child in children.prefix(remainingNodeBudget) {
                guard scheduled.insert(adapter.identity(of: child)).inserted else { continue }
                newChildren.append(child)
                if scheduled.count == Self.maxNodes { break }
            }
            stack.append(contentsOf: newChildren.reversed().map { ($0, current.depth + 1) })
        }
        return result
    }
}

@MainActor
final class AccessibilityContext: AccessibilityContextProviding {
    private let adapter = SystemAccessibilityNodeAdapter()

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

    func focusedWindowMetadata(pid: pid_t) -> AccessibilityWindowMetadata? {
        guard let window = adapter.focusedWindow(pid: pid) else { return nil }
        return AccessibilityWindowMetadata(
            windowID: adapter.numberAttribute("AXWindowNumber", from: window).map { CGWindowID($0.uint32Value) },
            title: adapter.stringAttribute(kAXTitleAttribute, from: window)
        )
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
final class SystemAccessibilityNodeAdapter: AccessibilityNodeAdapting, SelectionAccessibilityAdapting {
    typealias Node = AXUIElement
    typealias Identity = AXNodeIdentity

    func identity(of node: AXUIElement) -> AXNodeIdentity {
        AXNodeIdentity(element: node)
    }

    func isSecure(_ node: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: node)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(node, "AXProtectedContent" as CFString, &value)
        let protected = result == .success && (value as? Bool == true || (value as? NSNumber)?.boolValue == true)
        return Self.isSecure(role: role, protected: protected)
    }

    nonisolated static func isSecure(role: String?, protected: Bool) -> Bool {
        role == "AXSecureTextField" || protected
    }

    func visibleText(of node: AXUIElement) -> String? {
        let textRoles: Set<String> = [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole]
        guard let role = stringAttribute(kAXRoleAttribute, from: node), textRoles.contains(role) else { return nil }
        return stringAttribute(kAXValueAttribute, from: node)
    }

    func children(of node: AXUIElement, maxCount: Int) -> [AXUIElement] {
        guard maxCount > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(
            node,
            kAXChildrenAttribute as CFString,
            0,
            maxCount,
            &values
        ) == .success, let values = values as? [AnyObject] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
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

    func numberAttribute(_ name: String, from element: AXUIElement) -> NSNumber? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? NSNumber
    }

    func selectedTextRange(of element: AXUIElement) -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func selectedText(of element: AXUIElement) -> String? {
        stringAttribute(kAXSelectedTextAttribute, from: element)
    }

    func elementsEqual(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return CFEqual(lhs, rhs)
    }

    func replaceSelectedText(of element: AXUIElement, with text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

}
