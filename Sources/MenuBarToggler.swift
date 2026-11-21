import Foundation

enum MenuBarTarget {
    case system
    case player(String?)
}

@MainActor
protocol MenuBarToggling: AnyObject {
    func apply(shouldHide: Bool, isFullScreen: Bool, target: MenuBarTarget)
    func resetToVisible()
}

@MainActor
final class MenuBarToggler: MenuBarToggling {
    private static let key = "AppleMenuBarVisibleInFullscreen" as CFString
    private static let user = kCFPreferencesCurrentUser
    private static let host = kCFPreferencesAnyHost
    private let recoveryURL = subsystemSupportURL("player-menu-restore.plist")
    private var playerMode: Bool
    private var activePlayer: String?

    init(playerMode: Bool) {
        self.playerMode = playerMode
        _ = restorePlayer()
    }

    func apply(shouldHide: Bool, isFullScreen: Bool, target: MenuBarTarget) {
        switch target {
        case .system:
            if playerMode, !restorePlayer() {
                return
            }
            playerMode = false
            if isFullScreen {
                write(!shouldHide as CFBoolean, domain: kCFPreferencesAnyApplication)
            }
        case let .player(bundle):
            if !playerMode {
                resetToVisible()
            }
            playerMode = true
            let nextPlayer = shouldHide && isFullScreen ? bundle : nil
            guard nextPlayer != activePlayer, restorePlayer(), let nextPlayer else { return }
            hideForPlayer(nextPlayer)
        }
    }

    func resetToVisible() {
        if playerMode {
            _ = restorePlayer()
        } else {
            write(true as CFBoolean, domain: kCFPreferencesAnyApplication)
        }
    }

    private func hideForPlayer(_ bundle: String) {
        guard let recoveryURL else { return }
        let domain = bundle as CFString
        var record: [String: Any] = ["bundle": bundle]
        record["previous"] = CFPreferencesCopyValue(Self.key, domain, Self.user, Self.host)
        do {
            // Save the exact previous value (including absence) before overriding it.
            // A new daemon can then restore it even after a crash.
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: record,
                format: .binary,
                options: 0,
            )
            try data.write(to: recoveryURL, options: .atomic)
            if write(false as CFBoolean, domain: domain) {
                activePlayer = bundle
            }
        } catch {
            warn("could not save the player's menu preference: \(error)")
        }
    }

    @discardableResult
    private func restorePlayer() -> Bool {
        guard let recoveryURL, FileManager.default.fileExists(atPath: recoveryURL.path) else {
            activePlayer = nil
            return true
        }
        do {
            let data = try Data(contentsOf: recoveryURL)
            guard let record = try PropertyListSerialization.propertyList(
                      from: data,
                      format: nil,
                  ) as? [String: Any],
                  let bundle = record["bundle"] as? String, !bundle.isEmpty
            else {
                warn("invalid saved player menu preference")
                return false
            }
            let domain = bundle as CFString
            // Preserve a change made by the user or the player during playback.
            if let current = CFPreferencesCopyValue(Self.key, domain, Self.user, Self.host),
               CFEqual(current, kCFBooleanFalse),
               !write(record["previous"] as CFPropertyList?, domain: domain)
            {
                return false
            }
            try FileManager.default.removeItem(at: recoveryURL)
            activePlayer = nil
            return true
        } catch {
            warn("could not restore the player's menu preference: \(error)")
            return false
        }
    }

    @discardableResult
    private func write(_ value: CFPropertyList?, domain: CFString) -> Bool {
        CFPreferencesSetValue(Self.key, value, domain, Self.user, Self.host)
        guard CFPreferencesSynchronize(domain, Self.user, Self.host) else {
            warn("could not synchronize the fullscreen menu preference")
            return false
        }
        for name in [
            "AppleInterfaceMenuBarHidingChangedNotification",
            "AppleInterfaceFullScreenMenuBarVisibilityChangedNotification",
        ] {
            DistributedNotificationCenter.default().postNotificationName(
                .init(name), object: nil, userInfo: nil, deliverImmediately: true,
            )
        }
        return true
    }
}
