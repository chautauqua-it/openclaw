import AVFoundation
import Foundation
import Observation

/// Records a single utterance on the Watch microphone with metering-based
/// end-of-speech detection. watchOS has no Speech framework, so the audio file
/// is shipped to the iPhone for transcription.
@MainActor
@Observable
final class WatchVoiceRecorder: NSObject {
    enum Outcome: Equatable {
        case captured(URL)
        case empty
        case failed(String)
    }

    private static let speechThresholdDb: Float = -38
    private static let silenceHoldSeconds: TimeInterval = 1.4
    private static let noSpeechTimeoutSeconds: TimeInterval = 8
    private static let maxDurationSeconds: TimeInterval = 30

    private(set) var isRecording = false
    private(set) var normalizedLevel: Double = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt: Date?
    private var heardSpeech = false
    private var silenceStartedAt: Date?
    private var completion: ((Outcome) -> Void)?

    func start(completion: @escaping (Outcome) -> Void) {
        guard !self.isRecording else {
            completion(.failed("Registrazione già in corso"))
            return
        }
        self.completion = completion
        Task { @MainActor in
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                self.finish(.failed("Permesso microfono negato"))
                return
            }
            self.beginRecording()
        }
    }

    func stopAndDeliver() {
        guard self.isRecording else { return }
        self.concludeRecording(discard: false)
    }

    func cancel() {
        guard self.isRecording else { return }
        self.concludeRecording(discard: true)
    }

    private func beginRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true, options: [])
        } catch {
            self.finish(.failed("Audio non disponibile"))
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-talk-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                self.finish(.failed("Microfono non avviato"))
                return
            }
            self.recorder = recorder
        } catch {
            self.finish(.failed("Microfono non avviato"))
            return
        }

        self.isRecording = true
        self.startedAt = Date()
        self.heardSpeech = false
        self.silenceStartedAt = nil
        self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickMeter()
            }
        }
    }

    private func tickMeter() {
        guard self.isRecording, let recorder = self.recorder, let startedAt = self.startedAt else {
            return
        }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        self.normalizedLevel = Double(max(0, min(1, (power + 50) / 50)))

        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        if power > Self.speechThresholdDb {
            self.heardSpeech = true
            self.silenceStartedAt = nil
        } else if self.heardSpeech {
            if let silenceStartedAt = self.silenceStartedAt {
                if now.timeIntervalSince(silenceStartedAt) >= Self.silenceHoldSeconds {
                    self.concludeRecording(discard: false)
                    return
                }
            } else {
                self.silenceStartedAt = now
            }
        }

        if !self.heardSpeech, elapsed >= Self.noSpeechTimeoutSeconds {
            self.concludeRecording(discard: true)
            return
        }
        if elapsed >= Self.maxDurationSeconds {
            self.concludeRecording(discard: false)
        }
    }

    private func concludeRecording(discard: Bool) {
        let recorder = self.recorder
        let url = recorder?.url
        let hadSpeech = self.heardSpeech

        self.meterTimer?.invalidate()
        self.meterTimer = nil
        recorder?.stop()
        self.recorder = nil
        self.isRecording = false
        self.normalizedLevel = 0
        self.startedAt = nil

        if discard || !hadSpeech {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            self.finish(.empty)
            return
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            self.finish(.failed("File audio mancante"))
            return
        }
        self.finish(.captured(url))
    }

    private func finish(_ outcome: Outcome) {
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }
}
