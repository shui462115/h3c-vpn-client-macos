import AppKit

final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}

let fixtureDelegate = FixtureAppDelegate()
NSApplication.shared.delegate = fixtureDelegate
NSApplication.shared.run()
