import Events
import SwiftUI

struct MainWindow: View {
    @Bindable var app: AppModel
    @State private var selectedSessionID: String?

    var body: some View {
        VStack(spacing: 0) {
            if app.live != nil || app.recording != .idle {
                StatusStrip(app: app)
                Divider()
            }
            NavigationSplitView {
                SessionSidebar(app: app, selection: $selectedSessionID)
            } detail: {
                SessionView(app: app, sessionID: selectedSessionID)
            }
            .toolbar { recordControls }
        }
        .onAppear {
            app.refreshSummaries()
            if case .recording = app.recording { selectedSessionID = app.live?.id }
        }
        .onChange(of: app.live?.id) { _, newID in
            if let newID { selectedSessionID = newID }
        }
        .onChange(of: app.summaries.map(\.id)) { _, _ in
            // --open-window dev hook: auto-select the newest past session so a
            // populated transcript is visible for screenshot verification.
            if CommandLine.arguments.contains("--open-window"), selectedSessionID == nil {
                selectedSessionID = app.summaries.first { $0.id != app.live?.id }?.id
            }
        }
    }

    /// Always-present session controls: a Record/Stop primary button (this is
    /// the window's "new session" affordance) and the ambient always-on toggle.
    @ToolbarContentBuilder private var recordControls: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            switch app.recording {
            case .idle:
                Button { app.startRecording() } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start a new recording session")
            case .starting:
                Button {} label: { Label("Starting…", systemImage: "record.circle") }
                    .disabled(true)
            case .recording:
                Button { app.stopRecording() } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red)
                .help("Stop the current session")
            case .finishing:
                Button {} label: { Label("Finishing…", systemImage: "stop.circle") }
                    .disabled(true)
            }
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $app.ambientMode) {
                Label("Ambient", systemImage: "infinity")
            }
            .toggleStyle(.button)
            .help("Ambient always-on mode — auto-records and rolls over sessions")
        }
    }
}
