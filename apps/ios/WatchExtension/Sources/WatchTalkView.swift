import SwiftUI

struct WatchTalkView: View {
    var controller: WatchTalkController
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(self.controller.statusLabel)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(self.isError ? Color.red : Color.primary)

            ScrollView {
                VStack(spacing: 8) {
                    if !self.controller.partialTranscript.isEmpty {
                        Text(self.controller.partialTranscript)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !self.controller.replyText.isEmpty {
                        Text(self.controller.replyText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if self.controller.conversationActive {
                if self.controller.phase == .listening {
                    Button {
                        self.controller.finishListeningEarly()
                    } label: {
                        Label("Ho finito", systemImage: "waveform")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .tint(.green)
                }
                Button(role: .destructive) {
                    self.controller.stopConversation()
                } label: {
                    Label("Termina", systemImage: "stop.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            } else if self.controller.isBusy {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            } else {
                Button {
                    self.controller.startConversation()
                } label: {
                    Label("Conversazione", systemImage: "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .tint(.accentColor)

                TextFieldLink(prompt: Text("Parla con Spock")) {
                    Label("Detta", systemImage: "keyboard")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                } onSubmit: { text in
                    self.controller.submit(transcript: text)
                }
            }
        }
        .padding(.horizontal, 8)
        .navigationTitle("Spock")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    self.controller.cancel()
                    self.onClose?()
                } label: {
                    Image(systemName: "xmark")
                }
            }
        }
    }

    private var isError: Bool {
        if case .error = self.controller.phase { return true }
        return false
    }
}
