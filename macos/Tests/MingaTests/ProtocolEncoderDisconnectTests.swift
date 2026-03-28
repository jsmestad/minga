/// Tests for ProtocolEncoder broken pipe / disconnect handling.
///
/// Verifies that the encoder survives a broken pipe without crashing,
/// throwing, or blocking the calling thread. This guards against the
/// regression where `FileHandle.write()` to a dead pipe raised an
/// uncatchable ObjC `NSFileHandleOperationException`, zombifying the app.

import Testing
import Foundation

@Suite("Encoder: Disconnect Safety")
struct EncoderDisconnectTests {

    // MARK: - disconnect() drops writes

    @Test("disconnect() causes subsequent writes to be silently dropped")
    func disconnectDropsWrites() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)

        // Send one frame before disconnect (should succeed).
        encoder.sendReady(cols: 80, rows: 24)

        // Disconnect the encoder.
        encoder.disconnect()

        // These should be silently dropped, not crash.
        encoder.sendKeyPress(codepoint: 0x61, modifiers: 0)
        encoder.sendResize(cols: 120, rows: 40)
        encoder.sendMouseEvent(row: 5, col: 10, button: 0, modifiers: 0,
                               eventType: 0, clickCount: 1)
        encoder.sendPasteEvent(text: "hello")
        encoder.sendLog(level: 1, message: "test")
        encoder.sendSelectTab(id: 1)
        encoder.sendExecuteCommand(name: "quit")

        // Close write end and read everything that was written.
        pipe.fileHandleForWriting.closeFile()
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()

        // Only the ready frame should have been written (13 bytes payload + 4 length).
        #expect(raw.count == 17)
    }

    @Test("disconnect() is idempotent")
    func disconnectIdempotent() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)

        encoder.disconnect()
        encoder.disconnect()
        encoder.disconnect()

        // Should not crash. Writes should still be dropped.
        encoder.sendKeyPress(codepoint: 0x61, modifiers: 0)

        pipe.fileHandleForWriting.closeFile()
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(raw.isEmpty)
    }

    // MARK: - Broken pipe detection

    @Test("writing to a closed pipe marks encoder as disconnected")
    func brokenPipeAutoDisconnects() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)

        // Close the read end to simulate the BEAM dying.
        // This makes the pipe broken: writes will get EPIPE.
        pipe.fileHandleForReading.closeFile()

        // Ignore SIGPIPE for this test (mirrors production setup).
        signal(SIGPIPE, SIG_IGN)

        // This write should hit EPIPE and auto-disconnect.
        // It must NOT crash, throw, or block.
        encoder.sendKeyPress(codepoint: 0x61, modifiers: 0)

        // Subsequent writes should be silently dropped (encoder is
        // now disconnected). If these crash, the auto-disconnect
        // didn't work.
        encoder.sendKeyPress(codepoint: 0x62, modifiers: 0)
        encoder.sendResize(cols: 100, rows: 50)
        encoder.sendPasteEvent(text: "should be dropped")
    }

    @Test("encoder survives rapid writes to a broken pipe")
    func brokenPipeRapidWrites() {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)

        // Close read end to break the pipe.
        pipe.fileHandleForReading.closeFile()

        signal(SIGPIPE, SIG_IGN)

        // Simulate a burst of user input arriving after the BEAM dies.
        // None of these should crash or block.
        for i: UInt32 in 0..<100 {
            encoder.sendKeyPress(codepoint: 0x61 + (i % 26), modifiers: 0)
        }
    }

    // MARK: - Thread safety

    @Test("disconnect() is safe to call from a background thread while main thread writes")
    func disconnectFromBackgroundThread() async {
        let pipe = Pipe()
        let encoder = ProtocolEncoder(output: pipe.fileHandleForWriting)

        // Simulate the race: reader thread calls disconnect() while
        // the main thread is still sending keystrokes.
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            // Writer task: rapid-fire key presses.
            group.addTask {
                for i: UInt32 in 0..<UInt32(iterations) {
                    encoder.sendKeyPress(codepoint: 0x61 + (i % 26), modifiers: 0)
                }
            }

            // Disconnector task: disconnect partway through.
            group.addTask {
                // Small yield to let some writes happen first.
                try? await Task.sleep(nanoseconds: 100_000) // 0.1ms
                encoder.disconnect()
            }
        }

        // If we get here without crashing or deadlocking, the test passes.
        // Close the pipe so it doesn't leak.
        pipe.fileHandleForWriting.closeFile()
    }
}
