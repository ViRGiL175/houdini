import AppKit

enum DisplayScope: RawRepresentable, Equatable {
    case all, external, display(UUID)

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "external": self = .external
        default:
            guard let id = UUID(uuidString: rawValue) else { return nil }
            self = .display(id)
        }
    }

    var rawValue: String {
        switch self {
        case .all: "all"
        case .external: "external"
        case let .display(uuid): uuid.uuidString
        }
    }

    static func uuid(of display: CGDirectDisplayID) -> UUID? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue()
        else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String)
    }

    func matches(_ display: CGDirectDisplayID) -> Bool {
        guard case let .display(uuid) = self else { return true }
        return Self.uuid(of: display) == uuid
    }
}

enum OtherScreenShade: String {
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
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
final class PlaybackDisplays {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]

    /// AX and Core Graphics use global coordinates from the top left.
    /// NSScreen.frame, used to position the panels below, uses AppKit coordinates.
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

    /// Dock can miss the entry event when Houdini starts inside a fullscreen Space.
    /// The Spaces preference is undocumented. Only accept a matching *visible*
    /// window ID and owner; stale, incomplete or unfamiliar records are ignored.
    static func externalFullscreenWindow(of pid: pid_t) -> CGDirectDisplayID? {
        guard let configuration = CFPreferencesCopyAppValue(
                  "SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString,
              ) as? [String: Any],
              let management = configuration["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]]
        else { return nil }

        var fullscreenIDs = Set<CGWindowID>()
        for monitor in monitors {
            guard let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces where space["type"] as? Int == 4 && space["pid"] as? pid_t == pid {
                if let id = space["fs_wid"] as? CGWindowID {
                    fullscreenIDs.insert(id)
                }
            }
        }
        guard !fullscreenIDs.isEmpty,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID,
              ) as? [[String: Any]]
        else { return nil }

        let screens = NSScreen.screens.compactMap(\.displayID).map { CGDisplayBounds($0) }
        var precedingWindows: [CGRect] = []
        for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == pid
            && window[kCGWindowLayer as String] as? Int == 0
        {
            guard let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  screens.contains(where: { !$0.intersection(rect).isEmpty }),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            if fullscreenIDs.contains(id) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                guard let display = externalDisplay(containing: center) else { return nil }
                // Chromium has separate toolbar windows above its fullscreen window.
                // A foreground document on another screen makes the target ambiguous.
                let displayBounds = CGDisplayBounds(display)
                guard !precedingWindows.contains(where: { frame in
                    frame.contains(center) || screens
                        .contains { $0 != displayBounds && !$0.intersection(frame).isEmpty }
                }) else { return nil }
                return display
            }
            precedingWindows.append(rect)
        }
        return nil
    }

    static func listExternalDisplays() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, CGDisplayIsBuiltin(id) == 0,
                  let uuid = DisplayScope.uuid(of: id) else { continue }
            print("\(uuid.uuidString)  \(screen.localizedName)")
        }
    }

    func clear() {
        BuiltInBacklight.shared.restore()
        for panel in panels.values {
            panel.orderOut(nil)
        }
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
        if shade != .dim {
            BuiltInBacklight.shared.restore()
        }
        var active = Set<CGDirectDisplayID>()
        for screen in screens {
            guard let id = screen.displayID, id != playbackDisplay else { continue }
            if shade == .dim, CGDisplayIsBuiltin(id) != 0 {
                BuiltInBacklight.shared.dim(id)
                continue
            }
            active.insert(id)
            let panel: NSPanel
            if let existing = panels[id] {
                panel = existing
            } else {
                panel = NSPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false,
                )
                panel.backgroundColor = .black
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
                panel.collectionBehavior = [
                    .canJoinAllSpaces,
                    .fullScreenAuxiliary,
                    .stationary,
                    .ignoresCycle,
                ]
                panels[id] = panel
            }
            if panel.frame != screen.frame {
                panel.setFrame(screen.frame, display: true)
            }
            panel.alphaValue = shade == .dim ? 0.75 : 1
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
        for id in panels.keys.filter({ !active.contains($0) }) {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
    }
}
