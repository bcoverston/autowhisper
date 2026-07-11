import AppKit
import SwiftUI

@main
struct AutowhisperApp: App {
    @State private var app = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(content: {
            MenuContent(app: app)
        }, label: {
            MenuBarLabel(app: app)
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

/// Frees the Metal-backed whisper contexts synchronously as the process exits,
/// avoiding the ggml Metal teardown abort that fires when they're instead torn
/// down during process teardown (bad destruction order). `applicationWill
/// Terminate` runs on the main thread and the app waits for it before exit, so
/// a synchronous free here happens while the Metal device is still valid.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        WhisperTranscriber.shared.shutdownSync()
        RecheckTranscriber.shared.shutdownSync()
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
