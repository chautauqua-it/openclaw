import SwiftUI

struct WatchTalkView: View {
    var controller: WatchTalkController
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
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

            if self.controller.isBusy {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            } else {
                TextFieldLink(prompt: Text("Parla con Spock")) {
                    Label("Parla", systemImage: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } onSubmit: { text in
                    self.controller.submit(transcript: text)
                }
                .tint(.accentColor)
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
