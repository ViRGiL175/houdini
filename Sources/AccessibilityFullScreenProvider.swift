import ApplicationServices

/// Dock's diagnostic fullscreen messages are absent on newer macOS builds.
/// Read the focused window's actual state when the owner has granted access.
@MainActor
struct AccessibilityFullScreenProvider {
    struct FocusedWindow {
        let fullscreen: DockFullScreenState
        var externalDisplay: CGDirectDisplayID?
    }

    func state(for pid: pid_t?, locateDisplay: Bool) -> FocusedWindow? {
        guard AXIsProcessTrusted() else { return nil }
        guard let pid else { return FocusedWindow(fullscreen: .initial) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &windowValue) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return FocusedWindow(fullscreen: .initial) }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        var fullScreenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString,
                                            &fullScreenValue) == .success,
            let fullScreenValue,
            CFGetTypeID(fullScreenValue) == CFBooleanGetTypeID()
        else { return FocusedWindow(fullscreen: .initial) }
        let fullscreen = CFBooleanGetValue(unsafeDowncast(fullScreenValue, to: CFBoolean.self))
        let state = DockFullScreenState(
            isFullScreen: fullscreen,
            fsOwnerPID: fullscreen ? FSOwnerPID(pid) : nil,
        )
        guard fullscreen, locateDisplay, let center = center(of: window) else {
            return FocusedWindow(fullscreen: state)
        }
        return FocusedWindow(
            fullscreen: state,
            externalDisplay: PlaybackDisplays.externalDisplay(containing: center),
        )
    }

    private func center(of window: AXUIElement) -> CGPoint? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let origin = value(kAXPositionAttribute, of: window),
              let extent = value(kAXSizeAttribute, of: window),
              AXValueGetValue(origin, .cgPoint, &position),
              AXValueGetValue(extent, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private func value(_ attribute: String, of window: AXUIElement) -> AXValue? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID()
        else { return nil }
        return unsafeDowncast(result, to: AXValue.self)
    }
}
