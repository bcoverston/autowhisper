import AppKit
import SwiftUI

/// The menu-bar item's icon. Uses custom monochrome template glyphs (tinted by
/// the system for light/dark/active) that the system rendering can't confuse
/// with a generic waveform: a converging-waveform mark with a center node —
/// hollow when idle, filled while recording. Falls back to SF Symbols if the
/// bundled templates are missing, and shows a warning glyph on issues.
struct MenuBarLabel: View {
    @Bindable var app: AppModel

    var body: some View {
        content
            .task {
                PolicyHook.shared.install()
                await AutoTest.runIfRequested(app)
            }
    }

    @ViewBuilder private var content: some View {
        if !app.issues.isEmpty {
            Image(systemName: "exclamationmark.triangle")
        } else if case .recording = app.recording {
            templateImage("menubar-rec") ?? Image(systemName: "waveform.circle.fill")
        } else {
            templateImage("menubar-idle") ?? Image(systemName: "waveform.circle")
        }
    }

    private func templateImage(_ name: String) -> Image? {
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let ns = NSImage(contentsOfFile: path) else { return nil }
        ns.isTemplate = true
        ns.size = NSSize(width: 18, height: 18)
        return Image(nsImage: ns)
    }
}
