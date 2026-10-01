/// Startup timing instrumentation. Visible in Instruments (os_signpost)
/// and Console.app without depending on the BEAM being alive.

import os
import Foundation
import Darwin

let startupLog = OSLog(subsystem: "com.minga.app", category: "Startup")
let renderLog = OSLog(subsystem: "com.minga.app", category: "Render")
let protocolLog = OSLog(subsystem: "com.minga.app", category: "Protocol")
let inputLog = OSLog(subsystem: "com.minga.app", category: "Input")

/// Emits opt-in startup probe timestamps to stderr, which is separate from the protocol transport.
func recordStartupPhase(_ phase: String, frameSequence: UInt32 = 0, presentedTime: Double = 0) {
    guard ProcessInfo.processInfo.environment["MINGA_STARTUP_TIMER"] == "1" else { return }
    let line = "[startup-native] \(phase) uptime_ns=\(DispatchTime.now().uptimeNanoseconds) frame=\(frameSequence) presented_time=\(presentedTime)\n"
    line.withCString { bytes in
        _ = Darwin.write(STDERR_FILENO, bytes, strlen(bytes))
    }
}
