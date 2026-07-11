// Spike d: MenuBarExtra + Window scene in an LSUIElement SwiftPM bundle.
// Self-driving: opens/closes the window 5×, verifying activation-policy flips
// and that no zombie windows or dock icon persist. Logs to Spikes/out/spike-shell.log.

import AppKit
import SwiftUI

nonisolated let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Spikes/out/spike-shell.log")

@MainActor
func slog(_ s: String) {
    let line = s + "\n"
    if let h = FileHandle(forWritingAtPath: logURL.path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

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
            MainActor.assumeIsolated {
                guard let closing = closingWindow, closing.title == "spike-shell" else { return }
                // Back to accessory when the last real window goes away.
                let remaining = NSApp.windows.filter { $0.title == "spike-shell" && $0.isVisible && $0 !== closing }
                if remaining.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                    slog("policy → accessory (window closed)")
                }
            }
        }
    }
}

struct DriverLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Image(systemName: "waveform.circle")
            .task { await drive() }
    }

    @MainActor
    func drive() async {
        PolicyHook.shared.install()
        try? FileManager.default.removeItem(at: logURL)
        slog("launch policy=\(NSApp.activationPolicy().rawValue) windows=\(visibleCount())")
        try? await Task.sleep(for: .seconds(1))

        var failures = 0
        for cycle in 1...5 {
            openWindow(id: "main")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            try? await Task.sleep(for: .seconds(1))
            let openOK = visibleCount() == 1 && NSApp.activationPolicy() == .regular
            slog("cycle \(cycle) open: windows=\(visibleCount()) policy=\(NSApp.activationPolicy().rawValue) \(openOK ? "OK" : "FAIL")")
            if !openOK { failures += 1 }

            dismissWindow(id: "main")
            try? await Task.sleep(for: .seconds(1))
            let closeOK = visibleCount() == 0 && NSApp.activationPolicy() == .accessory
            slog("cycle \(cycle) close: windows=\(visibleCount()) policy=\(NSApp.activationPolicy().rawValue) \(closeOK ? "OK" : "FAIL")")
            if !closeOK { failures += 1 }
        }
        slog(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
        NSApp.terminate(nil)
    }

    @MainActor
    func visibleCount() -> Int {
        NSApp.windows.filter { $0.title == "spike-shell" && $0.isVisible }.count
    }
}

@main
struct SpikeShellApp: App {
    var body: some Scene {
        MenuBarExtra(content: {
            Button("Quit") { NSApp.terminate(nil) }
        }, label: { DriverLabel() })

        Window("spike-shell", id: "main") {
            Text("spike-shell window").frame(width: 300, height: 200)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
