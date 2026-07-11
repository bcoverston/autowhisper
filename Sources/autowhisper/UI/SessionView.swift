import Events
import SwiftUI

struct SessionView: View {
    @Bindable var app: AppModel
    let sessionID: String?

    @State private var loaded: LoadedSession?

    struct LoadedSession {
        let id: String
        let segments: [DraftSegment]
        let artifacts: [Artifact]
        let audioExpired: Bool
    }

    var body: some View {
        Group {
            if let live = app.live, live.id == sessionID {
                VStack(spacing: 0) {
                    TranscriptView(segments: live.segments,
                                   recheckedIDs: live.recheckedIDs,
                                   corrections: live.corrections,
                                   isLive: true)
                    Divider()
                    ArtifactBar(artifacts: live.closedArtifacts, audioExpired: false)
                }
            } else if let loaded, loaded.id == sessionID {
                VStack(spacing: 0) {
                    TranscriptView(segments: loaded.segments,
                                   recheckedIDs: [], corrections: [:], isLive: false)
                    Divider()
                    ArtifactBar(artifacts: loaded.artifacts, audioExpired: loaded.audioExpired)
                }
            } else if sessionID != nil {
                ProgressView()
            } else {
                ContentUnavailableView("No session selected", systemImage: "waveform",
                                       description: Text("Pick a session, or start recording from the menu bar."))
            }
        }
        .task(id: sessionID) {
            guard let sessionID, app.live?.id != sessionID,
                  let summary = app.summaries.first(where: { $0.id == sessionID }) else { return }
            loaded = nil
            let dir = summary.dir
            let result = await Task.detached {
                LoadedSession(id: sessionID,
                              segments: SessionStore.loadDraftSegments(dir: dir),
                              artifacts: SessionStore.artifacts(dir: dir),
                              audioExpired: SessionStore.audioExpired(dir: dir))
            }.value
            loaded = result
        }
    }
}
