// Captures a Roblox Studio window by (partial) title, even when Studio sits on another Space behind a
// full-screen app: briefly activates Studio, captures the window, then restores the previous app.
// usage: studio-snap <titleContains|""> <out.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: studio-snap <title> <out.png>"); exit(2) }
let needle = args[1], out = args[2]
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let studio = list.filter {
    ($0[kCGWindowOwnerName as String] as? String ?? "").contains("Roblox") && ($0[kCGWindowLayer as String] as? Int) == 0
}
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
let titled = studio.filter { !needle.isEmpty && ($0[kCGWindowName as String] as? String ?? "").contains(needle) }
guard let win = (titled.isEmpty ? studio : titled).max(by: { area($0) < area($1) }),
      let id = win[kCGWindowNumber as String] as? Int,
      let pid = win[kCGWindowOwnerPID as String] as? Int32 else {
    print("no Roblox Studio window found"); exit(1)
}
func capture() -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(id)", out]
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}
if capture() == 0 { exit(0) }
let previous = NSWorkspace.shared.frontmostApplication
NSRunningApplication(processIdentifier: pid)?.activate(options: [])
Thread.sleep(forTimeInterval: 1.1)
let status = capture()
if let previous, previous.processIdentifier != pid { previous.activate(options: []) }
exit(status)
