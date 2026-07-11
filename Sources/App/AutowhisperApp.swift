import SwiftUI
import Events

@main
struct AutowhisperApp: App {
    var body: some Scene {
        MenuBarExtra("autowhisper", systemImage: "waveform.circle") {
            Text("autowhisper — scaffold")
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
