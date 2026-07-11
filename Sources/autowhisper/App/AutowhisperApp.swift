import AppKit
import SwiftUI

@main
struct AutowhisperApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        MenuBarExtra(content: {
            MenuContent(app: app)
        }, label: {
            Image(systemName: app.menuGlyph)
                .task {
                    PolicyHook.shared.install()
                    await AutoTest.runIfRequested(app)
                }
        })

        Window("autowhisper", id: "main") {
            MainWindow(app: app)
        }
        .defaultSize(width: 760, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Voices", id: "voices") {
            VoicesLibrary(app: app)
        }
        .defaultSize(width: 460, height: 380)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(app: app)
        }
    }
}

/// Flips the app back to accessory (no dock icon) when the last main window
/// closes. Opening flips to .regular so the window can take focus (LSUIElement).
@MainActor
final class PolicyHook {
    static let shared = PolicyHook()
    private var observer: Any?

    func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let closingWindow = note.object as? NSWindow
            let ours: Set<String> = ["autowhisper", "Voices"]
            MainActor.assumeIsolated {
                guard let closing = closingWindow, ours.contains(closing.title) else { return }
                let remaining = NSApp.windows.filter { ours.contains($0.title) && $0.isVisible && $0 !== closing }
                if remaining.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func windowOpened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
