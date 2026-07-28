import SwiftUI
import AppKit

@main
struct PreviewRenderer {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let hosting = NSHostingView(rootView: ContentView(model: VPNViewModel())
            .frame(width: 500, height: 780, alignment: .top))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 780)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "H3CVPNPreview", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "H3CVPNPreview", code: 2)
        }
        let output = CommandLine.arguments.dropFirst().first ?? "H3CVPN-preview.png"
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        window.close()
    }
}
