import SwiftUI

/// Full-screen voice conversation with Spock (OpenAI Realtime via the Mac mini
/// talk daemon). Presented from the home toolbar microphone button.
struct SpockTalkView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NodeAppModel.self) private var appModel
    // Istanza condivisa con CarPlay: se la conversazione è già attiva dall'auto
    // la vista la mostra e la controlla invece di aprire un secondo engine audio.
    @State private var manager = SpockTalkManager.shared
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
                kittMeter
                    .padding(.top, 10)
                micButton
                    .padding(.top, 18)
                footer
                    .padding(.top, 12)
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

    /// VU meter stile KITT: 3 colonne di segmenti rossi che pulsano quando
    /// Spock parla. Tap = spegne la conversazione (grigio) / la riavvia (rosso).
    private var kittMeter: some View {
        KittVoiceMeter(
            level: self.manager.speechLevel,
            active: self.manager.isActive,
            connecting: self.manager.phase == .connecting)
            .contentShape(Rectangle())
            .onTapGesture {
                if self.manager.isActive {
                    self.manager.stop()
                } else {
                    self.manager.start()
                }
            }
            .accessibilityLabel(self.statusText)
            .accessibilityHint(self.manager.isActive
                ? "Tocca per fermare la conversazione"
                : "Tocca per avviare la conversazione")
    }

    /// Tasto MIC stile pulsantiera KITT: muta il microfono. Spock continua a
    /// parlare ma non sente più.
    private var micButton: some View {
        Button {
            self.manager.toggleMute()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: self.manager.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .black))
                Text("MIC")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .kerning(3)
            }
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: 168, height: 52)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: self.manager.isMuted
                                ? [Color(red: 0.55, green: 0.55, blue: 0.55), Color(red: 0.38, green: 0.38, blue: 0.38)]
                                : [Color(red: 1.0, green: 0.72, blue: 0.25), Color(red: 0.95, green: 0.55, blue: 0.15)],
                            startPoint: .top,
                            endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.black.opacity(0.5), lineWidth: 1.5)
                    }
                    .shadow(
                        color: self.manager.isMuted ? .clear : Color(red: 1.0, green: 0.6, blue: 0.2).opacity(0.45),
                        radius: 12)
            }
        }
        .buttonStyle(.plain)
        .disabled(!self.manager.isActive)
        .opacity(self.manager.isActive ? 1 : 0.35)
        .animation(.easeOut(duration: 0.15), value: self.manager.isMuted)
        .accessibilityLabel(self.manager.isMuted ? "Riattiva microfono" : "Muta microfono")
        .accessibilityHint("Spock continua a parlare ma non ti sente")
    }

    private var footer: some View {
        Text(self.footerText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
    }

    private var statusText: String {
        if case .error = self.manager.phase { return "Errore" }
        if self.manager.holdMusicActive { return "Musica d'attesa — microfono in muto" }
        if self.manager.isMuted { return "Microfono in muto — Spock parla ma non ti sente" }
        switch self.manager.phase {
        case .idle: return "Conversazione ferma"
        case .connecting: return "Connessione…"
        case .listening: return "Ti ascolto"
        case .speaking: return "Spock sta parlando"
        case .error: return "Errore"
        }
    }

    private var footerText: String {
        if case .error = self.manager.phase { return "" }
        if self.manager.holdMusicActive { return "Tocca MIC per riattivare il microfono." }
        if self.manager.isMuted { return "Tocca MIC per riattivare il microfono." }
        switch self.manager.phase {
        case .idle: return "Tocca le barre per avviare la conversazione."
        case .listening: return "Parla pure: puoi anche interromperlo. Tocca le barre per fermare."
        case .speaking: return "Parla per interrompere."
        case .connecting: return "Collegamento al Mac mini via Tailscale…"
        case .error: return ""
        }
    }
}

/// VU meter in stile KITT (Supercar): tre colonne di segmenti rossi, la
/// centrale più alta, che si accendono simmetricamente dal centro in base al
/// livello della voce. Grigio spento quando la conversazione è ferma.
struct KittVoiceMeter: View {
    var level: Double
    var active: Bool
    var connecting: Bool

    private static let sideSegments = 9
    private static let centerSegments = 15
    private static let segmentSize = CGSize(width: 34, height: 13)
    private static let segmentGap: CGFloat = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !self.active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 14) {
                self.column(segments: Self.sideSegments, level: self.columnLevel(jitter: sin(t * 9.1) * 0.5 + 0.5, scale: 0.72))
                self.column(segments: Self.centerSegments, level: self.columnLevel(jitter: 1.0, scale: 1.0))
                self.column(segments: Self.sideSegments, level: self.columnLevel(jitter: sin(t * 7.3 + 1.9) * 0.5 + 0.5, scale: 0.72))
            }
        }
        .animation(.linear(duration: 0.06), value: self.level)
    }

    /// Livello per colonna: le laterali seguono il centro con un'oscillazione
    /// leggera così il meter "vive" come quello di KITT invece di muoversi in blocco.
    private func columnLevel(jitter: Double, scale: Double) -> Double {
        guard self.active else { return 0 }
        if self.connecting {
            // Respiro minimo durante la connessione.
            return 0.08 * jitter
        }
        let base = self.level * scale
        return min(1.0, base * (0.75 + 0.25 * jitter))
    }

    private func column(segments: Int, level: Double) -> some View {
        let litFromCenter = Int((Double(segments) / 2.0 * level).rounded())
        let center = segments / 2
        return VStack(spacing: Self.segmentGap) {
            ForEach(0..<segments, id: \.self) { index in
                let lit = abs(index - center) <= litFromCenter && self.active && level > 0.02
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(self.segmentColor(lit: lit))
                    .frame(width: Self.segmentSize.width, height: Self.segmentSize.height)
                    .shadow(color: lit ? Color.red.opacity(0.55) : .clear, radius: 6)
            }
        }
    }

    private func segmentColor(lit: Bool) -> Color {
        if !self.active {
            return Color(white: 0.22)
        }
        return lit
            ? Color(red: 0.94, green: 0.13, blue: 0.08)
            : Color(red: 0.30, green: 0.04, blue: 0.03)
    }
}
