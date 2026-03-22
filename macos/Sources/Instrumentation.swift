/// Startup timing instrumentation. Visible in Instruments (os_signpost)
/// and Console.app without depending on the BEAM being alive.

import os

let startupLog = OSLog(subsystem: "com.minga.app", category: "Startup")
