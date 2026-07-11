import SwiftUI

/// Manage enrolled voice profiles: on-device fingerprints, forgettable.
struct VoicesLibrary: View {
    @Bindable var app: AppModel
    @State private var profiles: [VoiceProfile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(profiles.count) enrolled voice\(profiles.count == 1 ? "" : "s")")
                        .font(.headline)
                    Text("on-device fingerprints · 256-d embeddings · never leave this mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            Divider()

            if profiles.isEmpty {
                ContentUnavailableView("No voices enrolled", systemImage: "person.wave.2",
                                       description: Text("Tag a speaker in a transcript to enroll their voice."))
                    .frame(maxHeight: .infinity)
            } else {
                List(profiles) { profile in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SpeakerColor.matched)
                            .frame(width: 11, height: 11)
                            .shadow(color: SpeakerColor.matched.opacity(0.6), radius: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName).font(.body.weight(.medium))
                            Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s") · enrolled \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            app.forgetVoice(profile.id)
                            profiles.removeAll { $0.id == profile.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this voice (deletes the profile + embedding)")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .task { profiles = await app.voiceProfiles() }
    }
}
