import AVFAudio
import Foundation
import Testing
@testable import OpenClaw

/// Copre la causa del ticket TKT-RT-20260910-01: con voice processing attivo,
/// il tap sul mic deve usare il formato PCM float dell'hardware in *output*
/// (`input.outputFormat(forBus: 0)`), non l'`inputFormat` grezzo. Qui si
/// verifica direttamente `SpockMicSender` (float 48 kHz mono -> PCM16
/// 24 kHz mono) e che il payload `input_audio_buffer.append` risultante non
/// sia silenzioso.
/// Contenitore thread-safe minimale per lo stato osservato dai closure dei
/// test (`testSendOverride`, `onLevel`), che sono `@Sendable` e in Swift 6
/// non possono catturare `var` locali per mutazione diretta. Le chiamate qui
/// sono comunque sincrone entro `handle(_:)`, ma il tipo resta genuinamente
/// sicuro (lock reale) invece di disattivare il controllo di concorrenza.
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.value = newValue
    }

    func get() -> Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

@Suite("SpockMicSender conversion")
struct SpockMicSenderConversionTests {
    @Test
    func `converte float 48kHz in PCM16 24kHz mono con payload non silenzioso`() throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false)
        else {
            Issue.record("formato input non costruibile")
            return
        }

        let sender = try #require(SpockMicSender(inputFormat: inputFormat, webSocket: nil))

        let frameCount: AVAudioFrameCount = 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0]
        else {
            Issue.record("buffer di input non costruibile")
            return
        }
        // Tono a 440 Hz, ampiezza 0.5: chiaramente non silenzioso dopo la
        // conversione, ma senza clipping.
        let sampleRate = 48000.0
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            channel[i] = Float(sin(2 * .pi * 440.0 * t) * 0.5)
        }
        buffer.frameLength = frameCount

        let capturedPayload = LockedBox<String?>(nil)
        sender.testSendOverride = { text in capturedPayload.set(text) }

        sender.handle(buffer)

        let payloadText = try #require(capturedPayload.get())
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: String])

        #expect(json["type"] == "input_audio_buffer.append")

        let base64Audio = try #require(json["audio"])
        let pcm16Data = try #require(Data(base64Encoded: base64Audio))
        #expect(pcm16Data.count > 0)
        #expect(pcm16Data.count.isMultiple(of: 2))

        // 24 kHz output da 1024 campioni a 48 kHz -> circa 512 campioni.
        let sampleCount = pcm16Data.count / 2
        #expect(sampleCount > 400 && sampleCount < 600)

        // Payload non silenzioso: almeno un campione PCM16 con ampiezza
        // significativa (il tono a 440 Hz/0.5 non deve azzerarsi).
        var maxAbsSample: Int16 = 0
        pcm16Data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let value = Int16(littleEndian: sample)
                maxAbsSample = Swift.max(maxAbsSample, value == .min ? .max : abs(value))
            }
        }
        #expect(maxAbsSample > 1000)
    }

    @Test
    func `il mute azzera il livello e non invia payload`() throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false)
        else {
            Issue.record("formato input non costruibile")
            return
        }

        let sender = try #require(SpockMicSender(inputFormat: inputFormat, webSocket: nil))
        sender.muted = true

        let capturedLevel = LockedBox<Float?>(nil)
        let didSend = LockedBox<Bool>(false)
        sender.onLevel = { level in capturedLevel.set(level) }
        sender.testSendOverride = { _ in didSend.set(true) }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 256) else {
            Issue.record("buffer di input non costruibile")
            return
        }
        buffer.frameLength = 256

        sender.handle(buffer)

        #expect(capturedLevel.get() == 0)
        #expect(didSend.get() == false)
    }
}
