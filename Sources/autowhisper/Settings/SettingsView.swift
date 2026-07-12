import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var app: AppModel
    @AppStorage("retentionDays") private var retentionDays = 30
    @AppStorage("confidenceThreshold") private var confidenceThreshold = 0.6
    @AppStorage("sameVoiceThreshold") private var sameVoiceThreshold = 0.65
    @AppStorage("voiceMatchMargin") private var voiceMatchMargin = 0.06
    @AppStorage("correctionIntervalSeconds") private var correctionIntervalSeconds = 120
    @AppStorage("ambientSilenceMinutes") private var ambientSilenceMinutes = 10
    @AppStorage("ambientMaxHours") private var ambientMaxHours = 4
    @AppStorage("ambientMinFreeGB") private var ambientMinFreeGB = 5
    @AppStorage("correctionBackend") private var correctionBackend = "cli"
    @AppStorage("llmModelCLI") private var llmModelCLI = "sonnet"
    @AppStorage("llmModelAPI") private var llmModelAPI = "claude-sonnet-5"
    @AppStorage("anthropicBaseURL") private var anthropicBaseURL = "https://api.anthropic.com"
    @AppStorage("bedrockRegion") private var bedrockRegion = "us-east-1"
    @AppStorage("bedrockModelID") private var bedrockModelID = ""
    @AppStorage("openaiBaseURL") private var openaiBaseURL = "https://api.openai.com"
    @AppStorage("openaiModel") private var openaiModel = "gpt-4o"
    @AppStorage("geminiBaseURL") private var geminiBaseURL = "https://generativelanguage.googleapis.com"
    @AppStorage("geminiModel") private var geminiModel = "gemini-2.5-flash"
    @State private var anthropicKey = ""
    @State private var awsAccessKeyID = ""
    @State private var awsSecret = ""
    @State private var awsSessionToken = ""
    @State private var openaiKey = ""
    @State private var geminiKey = ""
    @State private var backendTest: String?
    @State private var testing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var profiles: [VoiceProfile] = []

    var body: some View {
        Form {
          Section("General") {
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
          }

          Section("Ambient sessions") {
            Stepper("New session after \(ambientSilenceMinutes) min of silence",
                    value: $ambientSilenceMinutes, in: 1...120)
            Stepper("Max session length \(ambientMaxHours) h",
                    value: $ambientMaxHours, in: 1...24)
            Stepper("Pause below \(ambientMinFreeGB) GB free",
                    value: $ambientMinFreeGB, in: 1...100)
            Text("When these caps hit, the current session finalizes and (silence/length) a fresh one starts. Only affects ambient mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
          }

          Section("Transcription") {
            Slider(value: $confidenceThreshold, in: 0.3...0.9, step: 0.05) {
                Text("Re-check below \(confidenceThreshold, format: .number.precision(.fractionLength(2)))")
            }
            Text("Segments with mean token confidence under this threshold are re-transcribed with the large model before correction.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper("Correct every \(correctionIntervalSeconds) s",
                    value: $correctionIntervalSeconds, in: 30...600, step: 30)
            Text("How often draft segments are batched to the correction pass. Lower is fresher but makes more backend calls.")
                .font(.caption)
                .foregroundStyle(.secondary)
          }

          Section("Correction backend") {
            Picker("Provider", selection: $correctionBackend) {
                ForEach(LLM.Kind.allCases) { Text($0.label).tag($0.rawValue) }
            }
            backendConfig
            HStack {
                Button(testing ? "Testing…" : "Test backend") { testBackend() }
                    .disabled(testing)
                if let backendTest {
                    Text(backendTest).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
          }

          Section("Speaker matching") {
            Slider(value: $sameVoiceThreshold, in: 0.40...0.85, step: 0.01) {
                Text("Same-voice match ≥ \(sameVoiceThreshold, format: .number.precision(.fractionLength(2)))")
            } minimumValueLabel: {
                Text("looser").font(.caption2)
            } maximumValueLabel: {
                Text("stricter").font(.caption2)
            }
            Text("""
                How close a voice must match an enrolled profile (cosine similarity) to auto-label it; \
                a runner-up margin gate also prevents merging two similar voices. This threshold is \
                still being dialed in — the default (0.65) errs strict on purpose.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("""
                Prefer a missed match over a wrong one: an unlabeled speaker is a one-click tag, but a \
                mislabel has to be caught and corrected. Loosen only if a known person keeps showing as \
                “Speaker N”; tighten if you find yourself marking misidentifications.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            if abs(sameVoiceThreshold - 0.65) > 0.001 {
                Button("Reset to recommended (0.65)") { sameVoiceThreshold = 0.65 }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            Slider(value: $voiceMatchMargin, in: 0.02...0.20, step: 0.01) {
                Text("Runner-up margin ≥ \(voiceMatchMargin, format: .number.precision(.fractionLength(2)))")
            } minimumValueLabel: {
                Text("looser").font(.caption2)
            } maximumValueLabel: {
                Text("stricter").font(.caption2)
            }
            Text("The best-matching profile must beat the second-best by this much to auto-label — the guard against two similar voices merging. Raise it if the wrong one of two similar people keeps getting picked.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !profiles.isEmpty {
                let totalMisIDs = profiles.reduce(0) { $0 + $1.misIDs }
                Text("\(profiles.count) enrolled voice\(profiles.count == 1 ? "" : "s") · \(totalMisIDs) misidentification\(totalMisIDs == 1 ? "" : "s") corrected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if totalMisIDs > 0 {
                    Label("Voices are being confused for each other — go stricter (threshold or margin), or enroll more speech per voice.",
                          systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Button("Reveal calibration log in Finder") {
                NSWorkspace.shared.open(MatchLog.directory)
            }
            .buttonStyle(.link)
            .font(.caption)
            Text("Every auto-match decision and your corrections are logged locally (match-decisions/-corrections.jsonl) so the threshold can later be set from real data, not guesses.")
                .font(.caption2)
                .foregroundStyle(.secondary)
          }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(maxHeight: 640)
        .task { profiles = await app.voiceProfiles() }
    }

    @ViewBuilder private var backendConfig: some View {
        switch LLM.Kind(rawValue: correctionBackend) ?? .cli {
        case .cli:
            TextField("Model", text: $llmModelCLI)
            Text("Shells out to your local `claude` CLI and subscription. No key needed; the default path.")
                .font(.caption).foregroundStyle(.secondary)
        case .api:
            TextField("Base URL", text: $anthropicBaseURL)
            TextField("Model", text: $llmModelAPI)
            secretField("API key", .anthropicAPIKey, $anthropicKey)
            saveKeysButton
            Text("Key stored in the Keychain (or ANTHROPIC_API_KEY). Model ids drift — set the current one.")
                .font(.caption).foregroundStyle(.secondary)
        case .bedrock:
            TextField("Region", text: $bedrockRegion)
            TextField("Model id (e.g. anthropic.claude-…-v1:0)", text: $bedrockModelID)
            secretField("AWS access key id", .awsAccessKeyID, $awsAccessKeyID)
            secretField("AWS secret access key", .awsSecretAccessKey, $awsSecret)
            secretField("Session token (optional)", .awsSessionToken, $awsSessionToken)
            saveKeysButton
            Text("Credentials resolve from the Keychain, else AWS_* env vars, else ~/.aws/credentials [default]. The model id is region/account-specific.")
                .font(.caption).foregroundStyle(.secondary)
        case .openai:
            TextField("Base URL", text: $openaiBaseURL)
            TextField("Model", text: $openaiModel)
            secretField("API key", .openaiAPIKey, $openaiKey)
            saveKeysButton
            Text("Key stored in the Keychain (or OPENAI_API_KEY). Base URL is overridable for Azure/OpenAI-compatible gateways.")
                .font(.caption).foregroundStyle(.secondary)
        case .gemini:
            TextField("Base URL", text: $geminiBaseURL)
            TextField("Model", text: $geminiModel)
            secretField("API key", .geminiAPIKey, $geminiKey)
            saveKeysButton
            Text("Key stored in the Keychain (or GEMINI_API_KEY / GOOGLE_API_KEY). Model ids drift — set the current one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func secretField(_ label: String, _ key: Secrets.Key, _ text: Binding<String>) -> some View {
        HStack {
            SecureField(label, text: text)
            if Secrets.has(key) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("stored")
            }
        }
    }

    private var saveKeysButton: some View {
        Button("Save credentials to Keychain") {
            Secrets.save(.anthropicAPIKey, anthropicKey)
            Secrets.save(.awsAccessKeyID, awsAccessKeyID)
            Secrets.save(.awsSecretAccessKey, awsSecret)
            Secrets.save(.awsSessionToken, awsSessionToken)
            Secrets.save(.openaiAPIKey, openaiKey)
            Secrets.save(.geminiAPIKey, geminiKey)
            anthropicKey = ""; awsAccessKeyID = ""; awsSecret = ""; awsSessionToken = ""
            openaiKey = ""; geminiKey = ""
        }
        .font(.caption)
    }

    /// Runs the configured backend end-to-end on a tiny payload so API/Bedrock
    /// config can be verified without waiting for a real session.
    private func testBackend() {
        testing = true
        backendTest = nil
        Task { @MainActor in
            do {
                let payload = LLM.Payload(segments: [.init(
                    id: 0, t0: 0, t1: 1000, text: "helo wrld", avg_p: 0.5,
                    no_speech_prob: 0.1, alt_hypothesis: nil, speaker: nil)])
                let result = try await LLM.correct(payload, timeout: .seconds(60))
                backendTest = "✓ \(LLM.kind.label): “\(result[0] ?? "?")”"
            } catch {
                backendTest = "✗ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
