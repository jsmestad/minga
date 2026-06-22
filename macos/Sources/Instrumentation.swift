/// Startup timing instrumentation. Visible in Instruments (os_signpost)
/// and Console.app without depending on the BEAM being alive.

import os

let startupLog = OSLog(subsystem: "com.minga.app", category: "Startup")
let renderLog = OSLog(subsystem: "com.minga.app", category: "Render")
let protocolLog = OSLog(subsystem: "com.minga.app", category: "Protocol")
let inputLog = OSLog(subsystem: "com.minga.app", category: "Input")
