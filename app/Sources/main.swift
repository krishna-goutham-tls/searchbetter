import AppKit

let args = CommandLine.arguments
if args.contains("--selftest") {
    exit(SelfTest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
