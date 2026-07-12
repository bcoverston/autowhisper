import AppKit
import Foundation

/// `--autotest`: records ~25 s then exits, so the capture→archive path can be
/// verified from a shell (`open dist/autowhisper.app --args --autotest`).
enum AutoTest {
    @MainActor
    static func runIfRequested(_ app: AppModel) async {
        guard CommandLine.arguments.contains("--autotest") else { return }
        try? await Task.sleep(for: .seconds(2))
        if CommandLine.arguments.contains("--mute-mic") { app.micMuted = true }
        app.startRecording()
        try? await Task.sleep(for: .seconds(25))
        app.stopRecording()
        for _ in 0..<300 {
            if app.recording == .idle { break }
            try? await Task.sleep(for: .seconds(0.5))
        }
        // --tag-test: exercise the real tagging path — tag the most-spoken
        // speaker in the just-finished session as "TestSpeaker" (enrolls a
        // VoiceProfile). A shell then checks speakers.json was written.
        if CommandLine.arguments.contains("--tag-test"), let summary = app.summaries.first {
            let segments = SessionStore.loadDraftSegments(dir: summary.dir)
            let labels = segments.compactMap(\.speaker)
            if let top = Dictionary(grouping: labels, by: { $0 })
                .max(by: { $0.value.count < $1.value.count })?.key {
                _ = await app.tagSpeaker(label: top, as: "TestSpeaker", in: summary.dir)
            }
        }
        NSApp.terminate(nil)
    }
}
