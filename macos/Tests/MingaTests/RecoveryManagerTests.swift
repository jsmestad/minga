/// Tests for macOS freeze recovery state detection.

import Foundation
import Testing

@MainActor
@Suite("RecoveryManager")
struct RecoveryManagerTests {
    @Test("not unresponsive initially")
    func notUnresponsiveInitially() {
        let manager = RecoveryManager()

        #expect(manager.isUnresponsive() == false)
        #expect(manager.keysSinceLastRender == 0)
    }

    @Test("not unresponsive if no keys were sent")
    func notUnresponsiveWithoutPendingKeys() {
        let manager = RecoveryManager()
        manager.setLastBatchEndTimeForTesting(CFAbsoluteTimeGetCurrent() - 10.0)

        #expect(manager.isUnresponsive() == false)
    }

    @Test("becomes unresponsive after timeout with pending keys")
    func unresponsiveAfterTimeoutWithPendingKeys() {
        let manager = RecoveryManager()
        manager.onKeySent()
        manager.setLastBatchEndTimeForTesting(CFAbsoluteTimeGetCurrent() - 4.0)

        #expect(manager.isUnresponsive() == true)
    }

    @Test("render receipt resets pending keys and responsiveness")
    func renderReceiptResetsState() {
        let manager = RecoveryManager()
        manager.onKeySent()
        manager.setLastBatchEndTimeForTesting(CFAbsoluteTimeGetCurrent() - 4.0)
        #expect(manager.isUnresponsive() == true)

        manager.onRenderReceived()

        #expect(manager.isUnresponsive() == false)
        #expect(manager.keysSinceLastRender == 0)
    }
}
