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

if let status = Updater.commandLineTest(CommandLine.arguments) {
    exit(status)
}

/// Usage: --preview-update out.png available|checking|uptodate|downloading|failed [--dark]
if let index = CommandLine.arguments.firstIndex(of: "--preview-update"), CommandLine.arguments.count > index + 2 {
    let path = CommandLine.arguments[index + 1]
    let sample = UpdateRelease(
        version: "9.9.0", notes: "What changed\n- A window that shows what ran while the lid was closed\n- Updates install from the menu",
        download: URL(string: "https://example.com/App.dmg")!, page: URL(string: "https://example.com")!)
    let phase: Updater.Phase
    switch CommandLine.arguments[index + 2] {
    case "checking": phase = .checking
    case "uptodate": phase = .upToDate
    case "downloading": phase = .downloading(sample)
    case "failed": phase = .failed("The update did not install. The new app is not signed by thelaunch.space, so it was not installed.", sample)
    default: phase = .available(sample)
    }
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Updater.snapshot(phase, dark: CommandLine.arguments.contains("--dark"), to: path)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(root: rootArg)
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
