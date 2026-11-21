import AppKit
import ApplicationServices

@MainActor
struct DictationDestination {
    let bundleID: String?
    private let processID: pid_t?
    private let field: AXUIElement?

    init(checkFocusedField: Bool) {
        let app = NSWorkspace.shared.frontmostApplication
        bundleID = app?.bundleIdentifier
        processID = app?.processIdentifier
        if let app, checkFocusedField, AXIsProcessTrusted() {
            field = Self.focusedField(app.processIdentifier)
        } else {
            field = nil
        }
    }

    func insert(_ text: String) -> Bool {
        guard let processID, let field, processID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let current = Self.focusedField(processID), CFEqual(current, field) else { return false }
        var subrole: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole)
        guard result == .success || result == .noValue || result == .attributeUnsupported,
              subrole as? String != kAXSecureTextFieldSubrole else { return false }
        var editable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &editable) == .success,
              editable.boolValue else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private static func focusedField(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let field = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(field, 0.2)
        return field
    }
}
