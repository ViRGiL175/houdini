import Foundation
@testable import houdini
import Testing

struct BuiltInBacklightTests {
    @Test("Restore the starting brightness after drift and confirm it by reading the display")
    func restoreAfterBrightnessDrift() {
        let change = BuiltInBacklight.Change(screen: UUID(), previous: 0.4, dimmed: 0.1)
        var reportedLevel: Float = 0.06

        // The display accepts the first write but still reports the drifted level.
        let firstAttempt = change.restore(read: { reportedLevel }, write: { requested in
            #expect(requested == change.previous)
            return true
        })
        #expect(!firstAttempt)

        let retry = change.restore(read: { reportedLevel }, write: { requested in
            reportedLevel = requested
            return true
        })
        #expect(retry)
        #expect(reportedLevel == change.previous)
    }
}
