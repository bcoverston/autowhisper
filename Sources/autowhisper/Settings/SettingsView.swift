import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage("retentionDays") private var retentionDays = 30
    @AppStorage("confidenceThreshold") private var confidenceThreshold = 0.6
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Toggle("Ambient mode (always-on)", isOn: $app.ambientMode)
            Text("Records continuously while enabled and resumes at launch. Sessions split at long silences; empty stretches are discarded.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        loginItemError = nil
                    } catch {
                        loginItemError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Stepper("Keep audio for \(retentionDays) days", value: $retentionDays, in: 1...365)
            Text("Transcripts are kept forever; only audio chunks are purged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: $confidenceThreshold, in: 0.3...0.9, step: 0.05) {
                Text("Re-check below \(confidenceThreshold, format: .number.precision(.fractionLength(2)))")
            }
            Text("Segments with mean token confidence under this threshold are re-transcribed with the large model before correction.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
