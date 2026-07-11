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
        }
        .onAppear {
            app.refreshSummaries()
            if case .recording = app.recording { selectedSessionID = app.live?.id }
        }
        .onChange(of: app.live?.id) { _, newID in
            if let newID { selectedSessionID = newID }
        }
    }
}
