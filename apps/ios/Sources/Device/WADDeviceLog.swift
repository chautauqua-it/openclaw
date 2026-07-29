import Foundation
import UIKit

/// Ships lightweight diagnostic events to the Mac mini talk daemon
/// (`POST /devlog`) so app freezes and crashes can be inspected remotely
/// without pulling crash reports off the device.
///
/// Design constraints:
/// - Must never crash or block the app: every operation runs on a private
///   serial queue, network failures just keep events buffered.
/// - Events are persisted to disk on every append, so the "last breath"
///   before a crash or a watchdog kill survives and is uploaded at next
///   launch.
/// - A background watchdog pings the main thread and logs when it hangs
///   (>4 s) and when it recovers — that is exactly the "WAD si è bloccata
///   da sola" scenario that motivated this logger.
final class WADDeviceLog: @unchecked Sendable {
    static let shared = WADDeviceLog()

    private struct Event {
        let t: String
        let up: Double
        let tag: String
        let msg: String

        var json: [String: Any] { ["t": self.t, "up": self.up, "tag": self.tag, "msg": self.msg] }
    }

    private let queue = DispatchQueue(label: "ai.openclaw.devlog", qos: .utility)
    private let launchDate = Date()
    private var pending: [Event] = []
    private var inFlightCount = 0
    private var flushScheduled = false
    private var started = false

    private var deviceName = "iPhone"
    private var osVersion = ""
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    private var watchdogTimer: DispatchSourceTimer?
    private let pongLock = NSLock()
    private var lastPong = Date()
    private var hangReported: Date?
    private var watchdogFirstTick = true
    // In background iOS sospende il main run loop: senza questo flag il
    // watchdog segnalerebbe falsi hang al rientro in foreground.
    private var inBackground = false

    // Only touched on `queue`, so the non-Sendable formatter is safe here.
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private var pendingFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("wad-devlog-pending.json")
    }

    private var serverBaseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: "spockTalk.serverURL")
            ?? "https://mac-mini-di-stefano.tail1e9216.ts.net:40812"
        return URL(string: raw)
    }

    // MARK: - Public API

    /// Call once at app launch (main thread). Uploads any events left over
    /// from the previous run (crash last-breath) and starts the main-thread
    /// watchdog.
    func start() {
        let name = UIDevice.current.name
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        // Un cold launch in background (prewarm/PushKit) tiene il main run loop
        // sospeso: senza questo init il watchdog lo scambia per un hang UI.
        let launchedInBackground = UIApplication.shared.applicationState == .background
        self.pongLock.lock()
        self.inBackground = launchedInBackground
        self.pongLock.unlock()
        self.queue.async {
            guard !self.started else { return }
            self.started = true
            self.deviceName = name
            self.osVersion = os
            self.loadPersisted()
            self.appendLocked(tag: "app", msg: "launch (build \(self.build), \(os))")
            self.scheduleFlushLocked(after: 1)
        }
        self.startWatchdog()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil)
        { [weak self] _ in
            self?.log("app", "memory warning")
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil)
        { [weak self] _ in
            guard let self else { return }
            self.pongLock.lock()
            self.inBackground = true
            self.hangReported = nil
            self.pongLock.unlock()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil)
        { [weak self] _ in
            guard let self else { return }
            self.pongLock.lock()
            self.inBackground = false
            self.lastPong = Date()
            self.hangReported = nil
            self.pongLock.unlock()
        }
    }

    /// Records a diagnostic event; safe from any thread.
    func log(_ tag: String, _ msg: String) {
        self.queue.async {
            self.appendLocked(tag: tag, msg: msg)
            self.scheduleFlushLocked(after: 2)
        }
    }

    /// Synchronous disk-only variant for the uncaught exception handler:
    /// the process is about to die, so persist and let the next launch upload.
    func logCrashSync(_ msg: String) {
        self.queue.sync {
            self.appendLocked(tag: "crash", msg: msg)
        }
    }

    // MARK: - Buffer & persistence (all on `queue`)

    private func appendLocked(tag: String, msg: String) {
        let event = Event(
            t: self.isoFormatter.string(from: Date()),
            up: Date().timeIntervalSince(self.launchDate),
            tag: tag,
            msg: String(msg.prefix(1900)))
        self.pending.append(event)
        if self.pending.count > 500 {
            self.pending.removeFirst(self.pending.count - 500)
        }
        self.persistLocked()
    }

    private func persistLocked() {
        let payload = self.pending.map(\.json)
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: self.pendingFileURL, options: .atomic)
        }
    }

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: self.pendingFileURL),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        self.pending = items.compactMap { item in
            guard let t = item["t"] as? String, let tag = item["tag"] as? String, let msg = item["msg"] as? String
            else { return nil }
            return Event(t: t, up: item["up"] as? Double ?? -1, tag: tag, msg: msg)
        }
        if !self.pending.isEmpty {
            self.appendLocked(tag: "app", msg: "eventi recuperati dal run precedente: \(self.pending.count)")
        }
    }

    // MARK: - Upload (all on `queue`)

    private func scheduleFlushLocked(after seconds: TimeInterval) {
        guard !self.flushScheduled else { return }
        self.flushScheduled = true
        self.queue.asyncAfter(deadline: .now() + seconds) {
            self.flushScheduled = false
            self.flushLocked()
        }
    }

    private func flushLocked() {
        guard self.inFlightCount == 0, !self.pending.isEmpty, let base = self.serverBaseURL else { return }
        let batch = self.pending
        self.inFlightCount = batch.count
        var request = URLRequest(url: base.appendingPathComponent("devlog"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "device": self.deviceName,
            "build": self.build,
            "os": self.osVersion,
            "events": batch.map(\.json),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            self.inFlightCount = 0
            return
        }
        request.httpBody = data
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                let sent = self.inFlightCount
                self.inFlightCount = 0
                let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
                if ok {
                    self.pending.removeFirst(min(sent, self.pending.count))
                    self.persistLocked()
                    if !self.pending.isEmpty { self.scheduleFlushLocked(after: 2) }
                } else {
                    // Offline (Tailscale down, ecc.): keep buffering, retry later.
                    self.scheduleFlushLocked(after: 30)
                }
            }
        }.resume()
    }

    // MARK: - Main-thread watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watchdogFirstTick {
                // Il lavoro pesante di launch non è un hang: riparti a contare
                // da qui senza segnalare nulla.
                self.watchdogFirstTick = false
                self.pongLock.lock()
                self.lastPong = Date()
                self.hangReported = nil
                self.pongLock.unlock()
                return
            }
            DispatchQueue.main.async {
                self.pongLock.lock()
                let hangStart = self.hangReported
                self.lastPong = Date()
                self.hangReported = nil
                self.pongLock.unlock()
                if let hangStart {
                    let secs = Date().timeIntervalSince(hangStart)
                    self.log("hang", String(format: "main thread ripartito dopo %.1fs", secs))
                }
            }
            self.pongLock.lock()
            let silent = Date().timeIntervalSince(self.lastPong)
            let alreadyReported = self.hangReported != nil
            let background = self.inBackground
            if silent > 4, !alreadyReported, !background {
                self.hangReported = self.lastPong
            }
            self.pongLock.unlock()
            if silent > 4, !alreadyReported, !background {
                // Logged from the watchdog queue: the main thread is stuck, but
                // buffering + upload do not need it.
                self.appendLocked(tag: "hang", msg: String(format: "main thread bloccato da %.1fs (UI congelata)", silent))
                self.scheduleFlushLocked(after: 0.1)
            }
        }
        timer.resume()
        self.watchdogTimer = timer
    }
}
