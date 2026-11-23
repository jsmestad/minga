// Posts key presses to one running app and prints when each key-down was posted.
//
// Usage: post_keys PID KEY...
// KEY is one of: space, a, n, x, q, escape, return, colon, bang.
// Each output line is "KEY realtime_ns uptime_ns", sampled immediately before the key-down post.
// The events go to PID only, never to the frontmost app.

import CoreGraphics
import Foundation

let keyCodes: [String: CGKeyCode] = [
    "space": 49, "a": 0, "n": 45, "x": 7, "escape": 53, "q": 12, "return": 36,
]
let shiftedKeyCodes: [String: CGKeyCode] = ["colon": 41, "bang": 18]

let arguments = CommandLine.arguments.dropFirst()
guard let pidText = arguments.first, let pid = pid_t(pidText), arguments.count > 1 else {
    FileHandle.standardError.write("usage: post_keys PID KEY...\n".data(using: .utf8)!)
    exit(2)
}

let source = CGEventSource(stateID: .hidSystemState)

func now(_ clock: clockid_t) -> UInt64 { clock_gettime_nsec_np(clock) }

for (index, name) in arguments.dropFirst().enumerated() {
    let shifted = shiftedKeyCodes[name] != nil
    guard let code = keyCodes[name] ?? shiftedKeyCodes[name],
          let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else {
        FileHandle.standardError.write("unknown key: \(name)\n".data(using: .utf8)!)
        exit(2)
    }
    if shifted {
        down.flags = .maskShift
        up.flags = .maskShift
    }
    if index > 0 { usleep(30_000) }
    let realtime = now(CLOCK_REALTIME)
    let uptime = now(CLOCK_UPTIME_RAW)
    down.postToPid(pid)
    up.postToPid(pid)
    print("\(name) \(realtime) \(uptime)")
}
