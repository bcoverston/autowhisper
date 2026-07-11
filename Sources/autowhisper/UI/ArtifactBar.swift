import AppKit
import Events
import QuickLook
import SwiftUI

struct ArtifactBar: View {
    let artifacts: [Artifact]
    let audioExpired: Bool

    @State private var quickLookURL: URL?

    private var files: [Artifact] { artifacts.filter { $0.kind != .audioChunk } }
    private var chunks: [Artifact] { artifacts.filter { $0.kind == .audioChunk } }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(files) { artifact in
                chip(artifact.name) {
                    if FileManager.default.fileExists(atPath: artifact.url.path) {
                        NSWorkspace.shared.open(artifact.url)
                    }
                }
                .contextMenu { revealButton(artifact.url) }
            }
            if !chunks.isEmpty {
                Menu("\(chunks.count) audio chunk\(chunks.count == 1 ? "" : "s")") {
                    ForEach(chunks) { chunk in
                        Button(chunk.name) { quickLookURL = chunk.url }
                    }
                    Divider()
                    revealButton(chunks[0].url)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if audioExpired {
                Text("audio expired (retention)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .quickLookPreview($quickLookURL)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func revealButton(_ url: URL) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
