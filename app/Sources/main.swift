import AppKit

let args = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
if args.contains("--selftest") {
    exit(SelfTest.run())
}
let rootArg = argValue("--root").map { URL(fileURLWithPath: $0).standardizedFileURL.path }
if args.contains("--index") || args.contains("--query") || args.contains("--queries") {
    Cli.run(root: rootArg)   // no panel and no hotkey, safe while someone uses the Mac
}

if let q = argValue("--render"), let out = argValue("--out") {
    Cli.render(root: rootArg, query: q, to: out)   // draws off screen, never takes the keyboard
}

if let stage = argValue("--render-setup"), let out = argValue("--out") {
    SetupWindow.render(stage: stage, to: out)   // draws off screen, never takes the keyboard
}

let app = NSApplication.shared
let delegate = AppDelegate(root: rootArg)
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
