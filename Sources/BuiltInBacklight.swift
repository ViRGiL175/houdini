import AppKit

/// DisplayServices controls the Mac's backlight directly. Load its private API
/// optionally so an OS change cannot prevent the rest of Houdini from starting.
@MainActor
final class BuiltInBacklight {

    static let shared = BuiltInBacklight()

    private typealias Read = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Write = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let read: Read?
    private let write: Write?
    private let url = subsystemSupportURL("backlight-restore.json")

    private struct Change: Codable {
        let screen: UUID
        let previous: Float
        let dimmed: Float
    }

    private var change: Change?

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let library = dlopen(path, RTLD_LAZY)
        read = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Read.self) }
        write = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Write.self) }
    }

    /// Only the daemon holding the instance lock owns this recovery record.
    func recover() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            change = try JSONDecoder().decode(Change.self, from: Data(contentsOf: url))
            restore()
        } catch {
            warn("could not read saved backlight level: \(error)")
        }
    }

    private func level(on display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard read?(display, &value) == 0, (0 ... 1).contains(value) else { return nil }
        return value
    }

    func dim(_ display: CGDirectDisplayID) {
        guard change == nil, CGDisplayIsBuiltin(display) != 0, let write, let url,
              let id = DisplayScope.uuid(of: display), let previous = level(on: display)
        else { return }
        let record = Change(screen: id, previous: previous, dimmed: previous * 0.25)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            change = record
            if write(display, record.dimmed) != 0 {
                warn("could not dim the built-in display")
            }
        } catch {
            warn("could not save the backlight level: \(error)")
        }
    }

    func restore() {
        guard let change, let url, let write else { return }
        for screen in NSScreen.screens {
            guard let display = screen.displayID, CGDisplayIsBuiltin(display) != 0,
                  DisplayScope.uuid(of: display) == change.screen, let current = level(on: display) else { continue }
            // Leave the latest setting alone if the user or auto-brightness changed it.
            if abs(current - change.dimmed) < 0.01, write(display, change.previous) != 0 { return }
            do {
                try FileManager.default.removeItem(at: url)
                self.change = nil
            } catch {
                warn("could not clear saved backlight level: \(error)")
            }
            return
        }
    }
}
