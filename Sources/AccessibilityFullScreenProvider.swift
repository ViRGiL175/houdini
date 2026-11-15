import ApplicationServices

/// Dock's diagnostic fullscreen messages are absent on newer macOS builds.
/// Read the focused window's actual state when the owner has granted access.
@MainActor
struct AccessibilityFullScreenProvider {

    func state(for pid: pid_t?) -> DockFullScreenState? {
        guard AXIsProcessTrusted() else { return nil }
        guard let pid else { return .initial }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                          &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return .initial }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        var fullScreenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString,
                                          &fullScreenValue) == .success,
              let fullScreenValue,
              CFGetTypeID(fullScreenValue) == CFBooleanGetTypeID()
        else { return .initial }
        let fullscreen = CFBooleanGetValue(unsafeDowncast(fullScreenValue, to: CFBoolean.self))
        return DockFullScreenState(
            isFullScreen: fullscreen,
            fsOwnerPID: fullscreen ? FSOwnerPID(pid) : nil,
        )
    }
}
