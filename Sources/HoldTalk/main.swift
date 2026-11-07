import AppKit
import HoldTalkKit

if CommandLine.arguments.contains("--self-test") {
    SelfTest.runFromCommandLine(CommandLine.arguments)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = MenuBarApp()
    app.delegate = delegate // A weak reference, so keep it alive for the whole run.
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
