import SwiftUI

/// Full-screen voice conversation with Spock (OpenAI Realtime via the Mac mini
/// talk daemon). Presented from the home toolbar microphone button.
struct SpockTalkView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NodeAppModel.self) private var appModel
    @State private var manager = SpockTalkManager()
    @State private var copiedAll = false

    var accent: Color = .cyan

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.10), .black],
                startPoint: .top,
                endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                transcript
                orb
                    .padding(.vertical, 18)
                footer
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            self.appModel.beginSpockTalkCapture()
            self.manager.start()
        }
        .onDisappear {
            self.manager.stop()
            self.appModel.endSpockTalkCapture()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Spock")
                    .font(.title3.weight(.semibold))
                Text(self.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !self.manager.lines.isEmpty {
                Button {
                    UIPasteboard.general.string = self.manager.lines
                        .map { "\($0.role == .user ? "Io" : "Spock"): \($0.text)" }
                        .joined(separator: "\n")
                    withAnimation { self.copiedAll = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation { self.copiedAll = false }
                    }
                } label: {
                    Image(systemName: self.copiedAll ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copia tutta la conversazione")
            }
            Button {
                self.manager.stop()
                self.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chiudi conversazione")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if case .error(let message) = self.manager.phase {
                        errorCard(message)
                    }
                    ForEach(self.manager.lines) { line in
                        bubble(for: line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: self.manager.lines.count) { _, _ in
                if let last = self.manager.lines.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func bubble(for line: SpockTalkManager.Line) -> some View {
        HStack {
            if line.role == .user { Spacer(minLength: 40) }
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(line.role == .user ? self.accent.opacity(0.22) : .white.opacity(0.08))
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = line.text
                    } label: {
                        Label("Copia", systemImage: "doc.on.doc")
                    }
                }
            if line.role == .spock { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: line.role == .user ? .trailing : .leading)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connessione non riuscita", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Riprova") { self.manager.start() }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(self.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.06))
        }
    }

    private var orb: some View {
        ZStack {
            Circle()
                .fill(self.orbColor.opacity(0.16))
                .frame(width: 132, height: 132)
                .scaleEffect(1.0 + self.manager.micLevel * 0.35)
                .animation(.easeOut(duration: 0.12), value: self.manager.micLevel)
            Circle()
                .fill(self.orbColor.opacity(0.30))
                .frame(width: 96, height: 96)
            Image(systemName: self.orbIcon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: self.manager.phase == .connecting)
        }
        .accessibilityLabel(self.statusText)
    }

    private var footer: some View {
        Text(self.footerText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
    }

    private var statusText: String {
        switch self.manager.phase {
        case .idle: "Pronto"
        case .connecting: "Connessione…"
        case .listening: "Ti ascolto"
        case .speaking: "Spock sta parlando"
        case .error: "Errore"
        }
    }

    private var footerText: String {
        switch self.manager.phase {
        case .listening: "Parla pure: puoi anche interromperlo."
        case .speaking: "Parla per interrompere."
        case .connecting: "Collegamento al Mac mini via Tailscale…"
        default: ""
        }
    }

    private var orbIcon: String {
        switch self.manager.phase {
        case .speaking: "waveform"
        case .error: "exclamationmark.triangle"
        default: "mic.fill"
        }
    }

    private var orbColor: Color {
        switch self.manager.phase {
        case .speaking: self.accent
        case .error: .orange
        case .connecting: .gray
        default: .green
        }
    }
}
