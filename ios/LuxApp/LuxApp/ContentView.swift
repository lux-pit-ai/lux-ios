import SwiftUI

struct ContentView: View {

    @StateObject private var audioManager = AudioManager()

    private let networkClient = NetworkClient()

    /// The most recent reply from the agent.
    @State private var agentReply: String?

    /// True while a message is in-flight to the backend.
    @State private var isSending = false

    /// Tracks an error to surface in the UI without disrupting the main transcript display.
    @State private var displayedError: String?

    var body: some View {
        VStack(spacing: 40) {
            Text("Lux")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Spacer()

            // Transcription / status area
            transcriptArea

            // Agent reply area
            if let reply = agentReply {
                replyArea(reply)
            }

            // Mic button
            micButton

            Spacer()
        }
        .padding()
        // Load the WhisperKit model as soon as the view appears so it is ready
        // before the first tap.
        .task {
            await audioManager.loadModel()
        }
        // Surface errors from AudioManager as an alert.
        .alert("Error", isPresented: .init(
            get: { displayedError != nil },
            set: { if !$0 { displayedError = nil } }
        )) {
            Button("OK", role: .cancel) { displayedError = nil }
        } message: {
            Text(displayedError ?? "")
        }
        // Watch for errors published by AudioManager.
        .onChange(of: audioManager.lastError) { _, error in
            guard let error else { return }
            displayedError = error.localizedDescription
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var transcriptArea: some View {
        Group {
            if audioManager.isLoadingModel {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading speech model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if audioManager.isRecording {
                Label("Listening…", systemImage: "waveform")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
            } else if isSending {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Sending…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let text = audioManager.transcribedText {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .transition(.opacity)
            } else {
                Text("Tap to speak")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 60)
        .animation(.easeInOut(duration: 0.2), value: audioManager.isRecording)
        .animation(.easeInOut(duration: 0.2), value: audioManager.transcribedText)
        .animation(.easeInOut(duration: 0.2), value: isSending)
    }

    @ViewBuilder
    private func replyArea(_ reply: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lux")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(reply)
                .font(.body)
                .multilineTextAlignment(.leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private var micButton: some View {
        Button {
            handleMicTap()
        } label: {
            ZStack {
                Circle()
                    .fill(buttonColor)
                    .frame(width: 80, height: 80)
                    .shadow(radius: audioManager.isRecording ? 8 : 2)
                    .animation(.easeInOut(duration: 0.15), value: audioManager.isRecording)

                if audioManager.isLoadingModel || isSending {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: audioManager.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        // Disable during model load or while a send is in-flight.
        .disabled(audioManager.isLoadingModel || isSending)
        .accessibilityLabel(audioManager.isRecording ? "Stop recording" : "Start recording")
    }

    private var buttonColor: Color {
        if audioManager.isLoadingModel || isSending { return .gray }
        return audioManager.isRecording ? .red : .accentColor
    }

    // MARK: - Actions

    private func handleMicTap() {
        if audioManager.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        agentReply = nil
        Task {
            let granted = await audioManager.requestMicrophonePermission()
            guard granted else {
                displayedError = AudioManagerError.permissionDenied.localizedDescription
                return
            }

            do {
                try audioManager.startRecording()
            } catch let error as AudioManagerError {
                displayedError = error.localizedDescription
            } catch {
                displayedError = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        Task {
            do {
                let text = try await audioManager.stopRecording()
                await sendToAgent(text: text)
            } catch let error as AudioManagerError {
                displayedError = error.localizedDescription
            } catch {
                displayedError = error.localizedDescription
            }
        }
    }

    /// POST the transcribed text to agent-memory and display the reply.
    private func sendToAgent(text: String) async {
        isSending = true
        defer { isSending = false }

        do {
            let reply = try await networkClient.send(text: text)
            withAnimation { agentReply = reply }
        } catch {
            displayedError = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}
