import AVFoundation
import Foundation
import Observation
import WatchKit

/// Drives the Watch push-to-talk loop. Speech-to-text uses the system dictation
/// input (presented by `WatchTalkView` via `TextFieldLink`), because the Speech
/// framework / `SFSpeechRecognizer` is not available on watchOS. The recognized
/// text is relayed to the iPhone (which forwards it to the target agent session),
/// and the reply is spoken back on-device with `AVSpeechSynthesizer`. No raw
/// audio crosses the WCSession link.
@MainActor
@Observable
final class WatchTalkController: NSObject {
    enum Phase: Equatable {
        case idle
        case sending
        case thinking
        case speaking
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var partialTranscript: String = ""
    private(set) var replyText: String = ""

    /// Agent the Action Button talks to. Resolved against the gateway agent
    /// directory on the iPhone side (by name or id), defaulting to Spock.
    var targetLabel: String = "Spock"

    private unowned let receiver: WatchConnectivityReceiver
    private let synthesizer = AVSpeechSynthesizer()
    private var activeCaptureId: String?

    init(receiver: WatchConnectivityReceiver) {
        self.receiver = receiver
        super.init()
        self.synthesizer.delegate = self
    }

    var isBusy: Bool {
        switch self.phase {
        case .sending, .thinking, .speaking:
            true
        case .idle, .error:
            false
        }
    }

    var statusLabel: String {
        switch self.phase {
        case .idle: "Tocca per parlare"
        case .sending: "Invio…"
        case .thinking: "Spock sta pensando…"
        case .speaking: "Spock risponde"
        case let .error(message): message
        }
    }

    // MARK: - Capture lifecycle

    /// Called by the view once the system dictation returns recognized text.
    func submit(transcript rawTranscript: String) {
        guard !self.isBusy else { return }
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }

        self.replyText = ""
        self.partialTranscript = transcript
        let captureId = UUID().uuidString
        self.activeCaptureId = captureId
        self.phase = .sending

        let label = self.targetLabel
        Task { @MainActor in
            let result = await self.receiver.sendTalkUtterance(
                captureId: captureId,
                transcript: transcript,
                targetLabel: label)
            guard self.activeCaptureId == captureId else { return }
            if result.errorMessage != nil {
                self.failCapture("iPhone non raggiungibile")
            } else if self.phase == .sending {
                self.phase = .thinking
            }
        }
    }

    func cancel() {
        self.synthesizer.stopSpeaking(at: .immediate)
        self.activeCaptureId = nil
        self.partialTranscript = ""
        self.phase = .idle
        self.deactivateAudioSession()
    }

    // MARK: - Inbound from iPhone

    func ingest(state message: WatchTalkStateMessage) {
        guard message.captureId == self.activeCaptureId else { return }
        if let text = message.text, !text.isEmpty {
            self.partialTranscript = text
        }
        switch message.state {
        case .thinking, .transcribing:
            self.phase = .thinking
        case .speaking:
            self.phase = .speaking
        case .listening:
            break
        case .idle:
            if self.phase != .speaking { self.phase = .idle }
        case .error:
            self.failCapture(message.text ?? "Errore")
        }
    }

    func ingest(reply message: WatchTalkReplyMessage) {
        guard message.captureId == self.activeCaptureId else { return }
        self.replyText = message.replyText
        self.speak(message.replyText)
    }

    // MARK: - Text-to-speech

    private func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.completeCapture()
            return
        }
        self.phase = .speaking
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            // Best effort; speech may still route to the default output.
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "it-IT")
        self.synthesizer.speak(utterance)
    }

    private func completeCapture() {
        self.activeCaptureId = nil
        self.phase = .idle
        self.deactivateAudioSession()
    }

    private func failCapture(_ message: String) {
        self.synthesizer.stopSpeaking(at: .immediate)
        self.activeCaptureId = nil
        self.phase = .error(message)
        self.deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension WatchTalkController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didFinish _: AVSpeechUtterance)
    {
        Task { @MainActor in
            self.completeCapture()
        }
    }

    nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didCancel _: AVSpeechUtterance)
    {
        Task { @MainActor in
            self.completeCapture()
        }
    }
}
