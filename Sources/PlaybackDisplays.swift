import AppKit

enum DisplayScope: String, CaseIterable {
    case all, external
}

enum OtherScreenShade: String, CaseIterable {
    case off, dim, black
}

struct DisplaySettings: Equatable {

    var scope: DisplayScope = .all
    var shade: OtherScreenShade = .off

    static func read() -> Self {
        Self(scope: read("displays", default: .all), shade: read("shade", default: .off))
    }

    static func read<Value: RawRepresentable>(_ key: String, default fallback: Value) -> Value
        where Value.RawValue == String
    {
        guard let url = subsystemSupportURL(key),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return fallback }
        return Value(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }
}

extension NSScreen {
    fileprivate var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
final class PlaybackDisplays {

    private var panels: [CGDirectDisplayID: NSPanel] = [:]

    // AX and Core Graphics use global coordinates from the top left.
    // NSScreen.frame, used to position the panels below, uses AppKit coordinates.
    static func externalDisplay(containing point: CGPoint) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  CGDisplayBounds(id).contains(point),
                  CGDisplayIsBuiltin(id) == 0,
                  CGDisplayIsInMirrorSet(id) == 0,
                  CGDisplayIsInHWMirrorSet(id) == 0
            else { continue }
            return id
        }
        return nil
    }

    func clear() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
    }

    func update(shade: OtherScreenShade, playbackDisplay: CGDirectDisplayID?) {
        guard shade != .off, let playbackDisplay else {
            clear()
            return
        }

        let screens = NSScreen.screens
        guard screens.contains(where: { $0.displayID == playbackDisplay }) else {
            clear()
            return
        }
        var active = Set<CGDirectDisplayID>()
        for screen in screens {
            guard let id = screen.displayID, id != playbackDisplay else { continue }
            active.insert(id)
            let panel: NSPanel
            if let existing = panels[id] {
                panel = existing
            } else {
                panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
                panel.backgroundColor = .black
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panels[id] = panel
            }
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: true) }
            panel.alphaValue = shade == .dim ? 0.75 : 1
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for id in panels.keys.filter({ !active.contains($0) }) {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
    }
}
