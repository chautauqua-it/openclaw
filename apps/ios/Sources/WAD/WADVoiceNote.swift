import AVFoundation
import SwiftUI

// MARK: - Registratore vocale (m4a/AAC) per la chat WAD

@MainActor
final class WADVoiceRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case denied
    }

    @Published var state: State = .idle
    @Published var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?
    static let maxDuration: TimeInterval = 180

    func start() async {
        guard self.state != .recording else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            self.state = .denied
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wad-vocale-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.record(forDuration: Self.maxDuration) else {
                throw NSError(domain: "wad.voice", code: 1)
            }
            self.recorder = recorder
            self.fileURL = url
            self.elapsed = 0
            self.state = .recording
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime
                }
            }
        } catch {
            self.cleanup()
        }
    }

    /// Ferma e restituisce l'audio registrato (nil se troppo corto o annullato).
    func stop() -> Data? {
        guard let recorder, let fileURL else {
            self.cleanup()
            return nil
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.cleanup()
        guard duration >= 0.7 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        let data = try? Data(contentsOf: fileURL)
        try? FileManager.default.removeItem(at: fileURL)
        return data
    }

    func cancel() {
        self.recorder?.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        self.cleanup()
    }

    private func cleanup() {
        self.timer?.invalidate()
        self.timer = nil
        self.recorder = nil
        self.fileURL = nil
        self.state = .idle
        self.elapsed = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension WADVoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Il limite massimo (180s) ferma la registrazione da solo: la UI resta in
        // stato recording e l'utente decide comunque se inviare o annullare.
    }
}

// MARK: - Player inline per gli allegati audio nelle bolle

@MainActor
final class WADVoicePlayerModel: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed
    }

    @Published var state: State = .idle
    @Published var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(url: URL) {
        switch self.state {
        case .playing:
            self.player?.pause()
            self.state = .paused
        case .paused:
            self.activateSession()
            self.player?.play()
            self.state = .playing
            self.startTimer()
        case .idle, .failed:
            self.load(url: url)
        case .loading:
            break
        }
    }

    private func load(url: URL) {
        self.state = .loading
        Task {
            do {
                // URLSession.shared porta con sé il cookie di sessione WAD.
                let (data, _) = try await URLSession.shared.data(from: url)
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.player = player
                self.activateSession()
                player.play()
                self.state = .playing
                self.startTimer()
            } catch {
                self.state = .failed
            }
        }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func startTimer() {
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    fileprivate func finished() {
        self.timer?.invalidate()
        self.timer = nil
        self.progress = 0
        self.state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension WADVoicePlayerModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }
}

struct WADVoiceAttachmentView: View {
    let url: URL
    let name: String

    @StateObject private var model = WADVoicePlayerModel()

    var body: some View {
        Button {
            self.model.toggle(url: self.url)
        } label: {
            HStack(spacing: 8) {
                switch self.model.state {
                case .loading:
                    ProgressView().controlSize(.small)
                case .playing:
                    Image(systemName: "pause.circle.fill").font(.title2)
                case .failed:
                    Image(systemName: "exclamationmark.circle").font(.title2)
                default:
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                            .font(.caption2)
                        Text("Messaggio vocale")
                            .font(.caption.weight(.semibold))
                    }
                    ProgressView(value: self.model.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Riproduci \(self.name)")
    }
}
