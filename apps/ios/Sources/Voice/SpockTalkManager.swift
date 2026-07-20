import AVFAudio
import Foundation
import Observation
import OSLog

/// Realtime voice conversation with the Spock agent.
///
/// The app asks the Mac mini talk daemon (Tailscale-only) for a short-lived
/// OpenAI Realtime client secret, then streams PCM16 24 kHz audio directly to
/// OpenAI over WebSocket. Tool calls are proxied back to the daemon, so no
/// long-lived API key ever reaches the device.
@MainActor
@Observable
final class SpockTalkManager {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case speaking
        case error(String)
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        var role: Role
        var text: String

        enum Role { case user, spock }
    }

    private(set) var phase: Phase = .idle
    private(set) var lines: [Line] = []
    var micLevel: Double = 0

    var isActive: Bool {
        switch self.phase {
        case .idle, .error: false
        default: true
        }
    }

    static let defaultServerURL = "https://mac-mini-di-stefano.tail1e9216.ts.net:40812"

    private let logger = Logger(subsystem: "ai.openclaw.node", category: "spock-talk")
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let audio = SpockTalkAudioPipeline()
    private var responseActive = false
    private var pendingToolResponseCreate = false
    private var pendingSpockText = ""
    private var audioObservers: [NSObjectProtocol] = []

    private var serverBaseURL: URL {
        let raw = UserDefaults.standard.string(forKey: "spockTalk.serverURL") ?? Self.defaultServerURL
        return URL(string: raw) ?? URL(string: Self.defaultServerURL)!
    }

    // MARK: - Lifecycle

    func start() {
        guard !self.isActive else { return }
        WADDeviceLog.shared.log("talk", "start modalità voce")
        self.phase = .connecting
        self.lines = []
        self.pendingSpockText = ""
        Task { await self.connect() }
    }

    func stop() {
        if self.isActive { WADDeviceLog.shared.log("talk", "stop modalità voce") }
        self.receiveTask?.cancel()
        self.receiveTask = nil
        self.webSocket?.cancel(with: .normalClosure, reason: nil)
        self.webSocket = nil
        self.teardownAudio()
        self.responseActive = false
        self.pendingToolResponseCreate = false
        self.micLevel = 0
        self.phase = .idle
    }

    private func fail(_ message: String) {
        self.logger.error("spock talk failed: \(message, privacy: .public)")
        WADDeviceLog.shared.log("talk.error", message)
        self.stop()
        self.phase = .error(message)
    }

    // MARK: - Connection

    private struct MintResponse: Decodable {
        var ok: Bool
        var clientSecret: String?
        var wsUrl: String?
        var error: String?
    }

    private func connect() async {
        let granted = await Self.requestMicPermission()
        guard granted else {
            self.fail("Permesso microfono negato: abilitalo in Impostazioni.")
            return
        }
        let mint: MintResponse
        do {
            var request = URLRequest(url: self.serverBaseURL.appendingPathComponent("session"))
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            let (data, _) = try await URLSession.shared.data(for: request)
            mint = try JSONDecoder().decode(MintResponse.self, from: data)
        } catch {
            self.fail("Server voce non raggiungibile (Tailscale attivo?): \(error.localizedDescription)")
            return
        }
        guard mint.ok, let secret = mint.clientSecret, let wsRaw = mint.wsUrl, let wsURL = URL(string: wsRaw) else {
            self.fail(mint.error ?? "Il server voce non ha restituito un token.")
            return
        }

        var wsRequest = URLRequest(url: wsURL)
        wsRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: wsRequest)
        self.webSocket = task
        task.resume()

        do {
            try await self.startAudio()
        } catch {
            self.fail("Audio non disponibile: \(error.localizedDescription)")
            return
        }

        WADDeviceLog.shared.log("talk", "connesso: sessione realtime + audio avviati")
        self.phase = .listening
        self.receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
    }

    private static func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: - Audio

    private func startAudio() async throws {
        self.installAudioObservers()
        let webSocket = self.webSocket
        try await self.audio.start(webSocket: webSocket, onLevel: { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                let raw = max(0, min(Double(level) * 10.0, 1.0))
                self.micLevel = (self.micLevel * 0.75) + (raw * 0.25)
            }
        })
    }

    private func installAudioObservers() {
        guard self.audioObservers.isEmpty else { return }
        let center = NotificationCenter.default
        self.audioObservers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: self.audio.engine,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor in self?.handleEngineConfigurationChange() }
        })
        self.audioObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main)
        { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        })
    }

    private func removeAudioObservers() {
        for observer in self.audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.audioObservers = []
    }

    private func handleEngineConfigurationChange() {
        guard self.isActive else { return }
        self.logger.info("audio engine configuration change; rebuilding graph")
        WADDeviceLog.shared.log("talk.audio", "config change → rebuild grafo")
        self.rebuildAudioGraph(context: "cambio uscita audio")
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            guard self.isActive else { return }
            self.logger.info("audio session interruption began")
            WADDeviceLog.shared.log("talk.audio", "interruzione sessione audio (began)")
            self.audio.detachGraph()
        case .ended:
            guard self.isActive else { return }
            self.logger.info("audio session interruption ended (options \(optionsRaw))")
            WADDeviceLog.shared.log("talk.audio", "interruzione finita (options \(optionsRaw)) → rebuild")
            self.rebuildAudioGraph(context: "ripresa dopo interruzione", reactivateSession: true)
        @unknown default:
            break
        }
    }

    private func rebuildAudioGraph(context: String, reactivateSession: Bool = false) {
        let webSocket = self.webSocket
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audio.rebuild(
                    webSocket: webSocket,
                    reactivateSession: reactivateSession,
                    onLevel: { [weak self] level in
                        Task { @MainActor in
                            guard let self else { return }
                            let raw = max(0, min(Double(level) * 10.0, 1.0))
                            self.micLevel = (self.micLevel * 0.75) + (raw * 0.25)
                        }
                    })
            } catch {
                self.fail("Audio interrotto (\(context)): \(error.localizedDescription)")
            }
        }
    }

    private func teardownAudio() {
        self.removeAudioObservers()
        self.audio.teardown()
    }

    // MARK: - Realtime events

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String? = switch message {
                case .string(let s): s
                case .data(let d): String(data: d, encoding: .utf8)
                @unknown default: nil
                }
                if let text { self.handleEvent(text) }
            } catch {
                if !Task.isCancelled, self.isActive {
                    self.fail("Connessione voce interrotta: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func handleEvent(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "response.output_audio.delta", "response.audio.delta":
            if let delta = event["delta"] as? String {
                self.phase = .speaking
                self.audio.play(base64: delta)
            }
        case "response.created":
            self.responseActive = true
        case "response.done":
            self.responseActive = false
            if self.isActive { self.phase = .listening }
            // A tool finished while another response was still active (e.g. we
            // kept chatting while ask_spock ran): fire the deferred turn now,
            // otherwise the tool answer would never be spoken.
            if self.pendingToolResponseCreate {
                self.pendingToolResponseCreate = false
                self.send(json: ["type": "response.create"])
            }
        case "input_audio_buffer.speech_started":
            // Barge-in: flush queued Spock audio and cancel the active response.
            self.audio.flushPlayback()
            if self.responseActive {
                self.send(json: ["type": "response.cancel"])
            }
            self.phase = .listening
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = (event["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !transcript.isEmpty
            {
                self.lines.append(Line(role: .user, text: transcript))
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = event["delta"] as? String {
                self.pendingSpockText += delta
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            let text = (event["transcript"] as? String ?? self.pendingSpockText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.pendingSpockText = ""
            if !text.isEmpty {
                self.lines.append(Line(role: .spock, text: text))
            }
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any],
               item["type"] as? String == "function_call",
               let name = item["name"] as? String,
               let callId = item["call_id"] as? String
            {
                let arguments = item["arguments"] as? String ?? "{}"
                Task { await self.runTool(name: name, arguments: arguments, callId: callId) }
            }
        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "errore realtime"
            self.logger.error("realtime error: \(message, privacy: .public)")
            WADDeviceLog.shared.log("talk.realtime", "errore server: \(message)")
        default:
            break
        }
    }

    private func send(json: [String: Any]) {
        guard let webSocket,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8)
        else { return }
        webSocket.send(.string(text)) { _ in }
    }

    // MARK: - Tools

    private func runTool(name: String, arguments: String, callId: String) async {
        WADDeviceLog.shared.log("talk.tool", "\(name) avviato")
        let toolStart = Date()
        var output = "{\"ok\":false,\"error\":\"tool non raggiungibile\"}"
        do {
            var request = URLRequest(url: self.serverBaseURL.appendingPathComponent("tool"))
            request.httpMethod = "POST"
            // ask_spock proxies to the real Spock agent and can take minutes on
            // heavy questions (finance/Excel); a short timeout here makes the
            // model report the tool as broken. Must stay above the daemon's own
            // execFile timeout so the daemon's fallback message wins.
            request.timeoutInterval = name == "ask_spock" ? 190 : 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let parsedArgs = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [:]
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "arguments": parsedArgs])
            let (data, _) = try await URLSession.shared.data(for: request)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let toolOutput = obj["output"],
               // .fragmentsAllowed: l'output può essere una stringa/numero top-level,
               // senza l'opzione la serializzazione fallisce e il tool risulta rotto
               let outData = try? JSONSerialization.data(withJSONObject: toolOutput, options: [.fragmentsAllowed])
            {
                output = String(data: outData, encoding: .utf8) ?? output
            }
        } catch {
            self.logger.error("tool proxy error: \(error.localizedDescription, privacy: .public)")
            WADDeviceLog.shared.log("talk.tool", "\(name) errore proxy: \(error.localizedDescription)")
        }
        WADDeviceLog.shared.log(
            "talk.tool",
            String(format: "%@ concluso in %.1fs (output %d char)", name, Date().timeIntervalSince(toolStart), output.count))
        self.send(json: [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output,
            ],
        ])
        if self.responseActive {
            self.pendingToolResponseCreate = true
        } else {
            self.send(json: ["type": "response.create"])
        }
    }
}

/// Owns the AVAudioEngine and performs every session/engine operation on a
/// private serial queue, never on the main thread. AURemoteIO's Initialize
/// performs a blocking RPC to the audio server that may need the caller's run
/// loop to answer a callback: on the main thread this deadlocks for ~10 s and
/// CoreAudio then aborts the process ("Initialize: RPC timeout. Apparently
/// deadlocked."), which was the freeze-then-close crash of builds 21-24.
private final class SpockTalkAudioPipeline: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "ai.openclaw.spocktalk.audio", qos: .userInitiated)
    private var playerAttached = false
    private var tapInstalled = false
    private var voiceProcessingEnabled = false
    private var micSender: SpockMicSender?
    private var playbackFormat: AVAudioFormat?

    func start(webSocket: URLSessionWebSocketTask?, onLevel: @escaping @Sendable (Float) -> Void) async throws {
        try await self.run {
            try self.startSessionLocked()
            try self.startGraphLocked(webSocket: webSocket, onLevel: onLevel)
        }
    }

    func rebuild(
        webSocket: URLSessionWebSocketTask?,
        reactivateSession: Bool,
        onLevel: @escaping @Sendable (Float) -> Void) async throws
    {
        try await self.run {
            self.detachGraphLocked()
            if reactivateSession {
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            try self.startGraphLocked(webSocket: webSocket, onLevel: onLevel)
        }
    }

    func detachGraph() {
        self.queue.async { self.detachGraphLocked() }
    }

    func teardown() {
        self.queue.async {
            self.detachGraphLocked()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    func play(base64: String) {
        self.queue.async {
            guard self.engine.isRunning,
                  let data = Data(base64Encoded: base64),
                  let format = self.playbackFormat,
                  !data.isEmpty
            else { return }
            let sampleCount = data.count / 2
            guard sampleCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
                  let channel = buffer.floatChannelData?[0]
            else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    channel[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
                }
            }
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            if !self.player.isPlaying, self.engine.isRunning {
                self.player.play()
            }
            self.player.scheduleBuffer(buffer)
        }
    }

    func flushPlayback() {
        self.queue.async {
            guard self.engine.isRunning else { return }
            self.player.stop()
            self.player.play()
        }
    }

    private func run(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            self.queue.async {
                do {
                    try body()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func startSessionLocked() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    /// Builds (or rebuilds) the engine graph against the current hardware
    /// formats. Called at start and again whenever CoreAudio reconfigures the
    /// engine (route change, Bluetooth handshake): after such a change the old
    /// tap/connection formats are stale and using them crashes with an
    /// uncatchable NSException, so we always re-query and re-wire.
    private func startGraphLocked(
        webSocket: URLSessionWebSocketTask?,
        onLevel: @escaping @Sendable (Float) -> Void) throws
    {
        // The .voiceChat session mode alone does not apply echo cancellation to
        // an AVAudioEngine graph: without voice processing on the IO units the
        // mic re-captures Spock's own speaker output and the model answers
        // itself. Must be enabled while the engine is stopped, before wiring.
        let input = self.engine.inputNode
        if !self.voiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
                self.voiceProcessingEnabled = true
            } catch {
                // Unsupported (e.g. simulator): degrade to no AEC rather than fail.
            }
        }

        guard let playback = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else {
            throw NSError(domain: "SpockTalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "formato playback non valido"])
        }
        self.playbackFormat = playback
        if !self.playerAttached {
            self.engine.attach(self.player)
            self.playerAttached = true
        }
        self.engine.connect(self.player, to: self.engine.mainMixerNode, format: playback)

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "SpockTalk", code: 2, userInfo: [NSLocalizedDescriptionKey: "formato microfono non valido"])
        }
        guard let sender = SpockMicSender(inputFormat: inputFormat, webSocket: webSocket) else {
            throw NSError(domain: "SpockTalk", code: 3, userInfo: [NSLocalizedDescriptionKey: "conversione audio non disponibile"])
        }
        sender.onLevel = onLevel
        self.micSender = sender
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            sender.handle(buffer)
        }
        self.tapInstalled = true

        self.engine.prepare()
        try self.engine.start()
        self.player.play()
    }

    private func detachGraphLocked() {
        if self.tapInstalled {
            self.engine.inputNode.removeTap(onBus: 0)
            self.tapInstalled = false
        }
        self.micSender = nil
        if self.player.isPlaying { self.player.stop() }
        if self.engine.isRunning { self.engine.stop() }
    }
}

/// Converts mic buffers to PCM16 24 kHz mono and streams them to the realtime
/// WebSocket. Runs on the audio tap thread; internally serialized by the tap.
private final class SpockMicSender: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let webSocket: URLSessionWebSocketTask?
    var onLevel: (@Sendable (Float) -> Void)?

    init?(inputFormat: AVAudioFormat, webSocket: URLSessionWebSocketTask?) {
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true),
            let converter = AVAudioConverter(from: inputFormat, to: output)
        else { return nil }
        self.outputFormat = output
        self.converter = converter
        self.webSocket = webSocket
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += channel[i] * channel[i] }
            self.onLevel?(sqrtf(sum / Float(n)))
        }

        let ratio = self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio + 32))
        guard let converted = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var conversionError: NSError?
        let status = self.converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, converted.frameLength > 0,
              let samples = converted.int16ChannelData?[0]
        else { return }
        let data = Data(bytes: samples, count: Int(converted.frameLength) * 2)
        let payload: [String: String] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8)
        else { return }
        self.webSocket?.send(.string(text)) { _ in }
    }
}
