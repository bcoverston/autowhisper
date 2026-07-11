import SwiftUI

struct MenuContent: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch app.recording {
        case .idle:
            Button("Start Recording") { app.startRecording() }
        case .starting:
            Text("Starting…")
        case .recording(let since):
            Text("Recording — started \(since.formatted(date: .omitted, time: .shortened))")
            Button("Stop Recording") { app.stopRecording() }
        case .finishing:
            Text("Finishing…")
        }
        if let issue = app.issues.first {
            Divider()
            Text("⚠︎ \(issue.kind.label)")
        }
        Divider()
        Button("Open autowhisper…") {
            openWindow(id: "main")
            PolicyHook.shared.windowOpened()
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

extension Events.IssueKind {
    var label: String {
        switch self {
        case .micPermissionDenied: "Microphone access denied"
        case .audioTapPermissionDenied: "System-audio access denied"
        case .tapInvalidated: "Audio capture failed"
        case .modelMissing: "Whisper model missing"
        case .claudeCLIFailed: "Claude correction failed"
        case .diskWriteFailed: "Disk write failed"
        }
    }
}

import Events
