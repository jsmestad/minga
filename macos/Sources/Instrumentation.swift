/// Startup timing instrumentation. Visible in Instruments (os_signpost)
/// and Console.app without depending on the BEAM being alive.

import os
import Foundation
import Darwin
import MingaUI

let startupLog = OSLog(subsystem: PortLogger.subsystem, category: "Startup")
let renderLog = OSLog(subsystem: PortLogger.subsystem, category: "Render")
let protocolLog = OSLog(subsystem: PortLogger.subsystem, category: "Protocol")
let inputLog = OSLog(subsystem: PortLogger.subsystem, category: "Input")

/// Interval signposts for the main-thread frame transaction path: `FrameStage`, `FrameFreeze`, and `FramePublish`.
///
/// They share the `Render` category with the renderer's `Frame` interval, so `xctrace` and Instruments record them with the existing frame signposts. Each frame emits at most one interval of each name per packet, and every interval carries `frame=<frameSeq>`. The dynamic-tracing category would make them free when nothing records, but `xctrace record` does not enable that category, so it cannot produce the receipt in `bench/frame_staging_main_thread.md`, which also measures the cost of these intervals.
let frameTransactionSignposter = OSSignposter(logHandle: renderLog)

/// Emits opt-in startup probe timestamps to stderr, which is separate from the protocol transport.
func recordStartupPhase(_ phase: String, frameSequence: UInt32 = 0, presentedTime: Double = 0) {
    guard ProcessInfo.processInfo.environment["MINGA_STARTUP_TIMER"] == "1" else { return }
    let line = "[startup-native] \(phase) uptime_ns=\(DispatchTime.now().uptimeNanoseconds) frame=\(frameSequence) presented_time=\(presentedTime)\n"
    line.withCString { bytes in
        _ = Darwin.write(STDERR_FILENO, bytes, strlen(bytes))
    }
}
