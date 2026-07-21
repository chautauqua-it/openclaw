import AVFoundation
import Foundation
import Observation
import WatchKit

/// Drives the Watch talk loop. watchOS has no Speech framework, so speech-to-text
/// happens on the iPhone: in conversation mode the Watch records the utterance
/// (`WatchVoiceRecorder`) and ships the audio file over WCSession for
/// transcription; the legacy dictation path (`TextFieldLink`) stays as fallback.
/// Replies are spoken on-device with `AVSpeechSynthesizer` using the best
/// available Italian voice.
@MainActor
@Observable
final class WatchTalkController: NSObject {
    enum Phase: Equatable {
        case idle
        case listening
        case sending
        case thinking
        case speaking
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var partialTranscript: String = ""
    private(set) var replyText: String = ""
    private(set) var conversationActive = false

    /// Agent the Action Button talks to. Resolved against the gateway agent
    /// directory on the iPhone side (by name or id), defaulting to Spock.
    var targetLabel: String = "Spock"

    private unowned let receiver: WatchConnectivityReceiver
    private let synthesizer = AVSpeechSynthesizer()
    let recorder = WatchVoiceRecorder()
    private var activeCaptureId: String?

    init(receiver: WatchConnectivityReceiver) {
        self.receiver = receiver
        super.init()
        self.synthesizer.delegate = self
    }

    var isBusy: Bool {
        switch self.phase {
        case .listening, .sending, .thinking, .speaking:
            true
        case .idle, .error:
            false
        }
    }

    var statusLabel: String {
        switch self.phase {
        case .idle: "Tocca per parlare"
        case .listening: "Ti ascolto…"
        case .sending: "Invio…"
        case .thinking: "Spock sta pensando…"
        case .speaking: "Spock risponde"
        case let .error(message): message
        }
    }

    // MARK: - Conversation mode (on-watch audio capture)

    func startConversation() {
        guard !self.conversationActive else { return }
        self.conversationActive = true
        self.replyText = ""
        self.partialTranscript = ""
        self.beginListening()
    }

    func stopConversation() {
        self.conversationActive = false
        self.recorder.cancel()
        self.synthesizer.stopSpeaking(at: .immediate)
        self.activeCaptureId = nil
        self.phase = .idle
        self.deactivateAudioSession()
    }

    private func beginListening() {
        guard self.conversationActive else { return }
        self.phase = .listening
        self.recorder.start { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case let .captured(url):
                self.sendAudio(url)
            case .empty:
                // Nothing said: end the conversation instead of looping forever.
                self.stopConversation()
            case let .failed(message):
                self.conversationActive = false
                self.failCapture(message)
            }
        }
    }

    /// User tapped while listening: close the utterance right away.
    func finishListeningEarly() {
        guard self.phase == .listening else { return }
        self.recorder.stopAndDeliver()
    }

    private func sendAudio(_ url: URL) {
        self.replyText = ""
        self.partialTranscript = ""
        let captureId = UUID().uuidString
        self.activeCaptureId = captureId
        self.phase = .sending

        let label = self.targetLabel
        Task { @MainActor in
            let sent = await self.receiver.sendTalkAudio(
                fileURL: url,
                captureId: captureId,
                targetLabel: label)
            guard self.activeCaptureId == captureId else { return }
            if sent {
                if self.phase == .sending { self.phase = .thinking }
            } else {
                self.conversationActive = false
                self.failCapture("iPhone non raggiungibile")
            }
        }
    }

    // MARK: - Dictation fallback

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
        self.conversationActive = false
        self.recorder.cancel()
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
        if let transcript = message.transcript, !transcript.isEmpty {
            self.partialTranscript = transcript
        }
        self.replyText = message.replyText
        self.speak(message.replyText)
    }

    // MARK: - Text-to-speech

    /// Best Italian voice on this Watch (premium > enhanced > default quality).
    /// `AVSpeechSynthesisVoice(language:)` alone can silently hand back a wrong
    /// or missing voice, which is how replies ended up sounding Spanish.
    private static func bestItalianVoice() -> AVSpeechSynthesisVoice? {
        let italianVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("it") }
        let ranked = italianVoices.sorted { lhs, rhs in
            Self.qualityRank(lhs.quality) > Self.qualityRank(rhs.quality)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: "it-IT")
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: 3
        case .enhanced: 2
        case .default: 1
        @unknown default: 0
        }
    }

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
        utterance.voice = Self.bestItalianVoice()
        self.synthesizer.speak(utterance)
    }

    private func completeCapture() {
        if case .error = self.phase { return }
        self.activeCaptureId = nil
        if self.conversationActive {
            // Loop: reopen the microphone for the next utterance.
            self.beginListening()
            return
        }
        self.phase = .idle
        self.deactivateAudioSession()
    }

    private func failCapture(_ message: String) {
        self.conversationActive = false
        self.recorder.cancel()
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
