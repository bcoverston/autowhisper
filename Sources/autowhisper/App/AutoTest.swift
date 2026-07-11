import AppKit
import Foundation

/// `--autotest`: records ~25 s then exits, so the capture→archive path can be
/// verified from a shell (`open dist/autowhisper.app --args --autotest`).
enum AutoTest {
    @MainActor
    static func runIfRequested(_ app: AppModel) async {
        guard CommandLine.arguments.contains("--autotest") else { return }
        try? await Task.sleep(for: .seconds(2))
        app.startRecording()
        try? await Task.sleep(for: .seconds(25))
        app.stopRecording()
        for _ in 0..<60 {
            if app.recording == .idle { break }
            try? await Task.sleep(for: .seconds(0.5))
        }
        NSApp.terminate(nil)
    }
}
