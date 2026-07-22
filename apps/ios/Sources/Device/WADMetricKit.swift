import Foundation
import MetricKit

/// Inoltra al devlog remoto le diagnostiche MetricKit: crash e hang con stack
/// trace (simbolicabili con il dSYM via atos) e i contatori di uscita
/// dell'app (jetsam, watchdog, ecc.) che spiegano i "riavvii" senza crash
/// report visibile. iOS consegna i payload alla prima apertura utile dopo
/// l'evento, quindi i riscontri arrivano al lancio successivo.
final class WADMetricSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = WADMetricSubscriber()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var parts: [String] = ["crash build=\(crash.metaData.applicationBuildVersion)"]
                if let reason = crash.terminationReason { parts.append("reason=\(reason)") }
                if let type = crash.exceptionType { parts.append("excType=\(type)") }
                if let code = crash.exceptionCode { parts.append("excCode=\(code)") }
                if let signal = crash.signal { parts.append("signal=\(signal)") }
                if let region = crash.virtualMemoryRegionInfo { parts.append("vm=\(region.prefix(120))") }
                WADDeviceLog.shared.log("metrickit.crash", parts.joined(separator: " "))
                Self.shipStack(crash.callStackTree, kind: "crash")
            }
            for hang in payload.hangDiagnostics ?? [] {
                WADDeviceLog.shared.log(
                    "metrickit.hang",
                    "hang durata=\(hang.hangDuration) build=\(hang.metaData.applicationBuildVersion)")
                Self.shipStack(hang.callStackTree, kind: "hang")
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                WADDeviceLog.shared.log(
                    "metrickit.cpu",
                    "cpu exception totale=\(cpu.totalCPUTime) build=\(cpu.metaData.applicationBuildVersion)")
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let bg = exits.backgroundExitData
            let fg = exits.foregroundExitData
            let summary = "exit fg[abnormal=\(fg.cumulativeAbnormalExitCount)"
                + " watchdog=\(fg.cumulativeAppWatchdogExitCount)"
                + " memLimit=\(fg.cumulativeMemoryResourceLimitExitCount)"
                + " badAccess=\(fg.cumulativeBadAccessExitCount)"
                + " illegal=\(fg.cumulativeIllegalInstructionExitCount)]"
                + " bg[abnormal=\(bg.cumulativeAbnormalExitCount)"
                + " watchdog=\(bg.cumulativeAppWatchdogExitCount)"
                + " memPressure=\(bg.cumulativeMemoryPressureExitCount)"
                + " memLimit=\(bg.cumulativeMemoryResourceLimitExitCount)"
                + " taskTimeout=\(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount)"
                + " normal=\(bg.cumulativeNormalAppExitCount)]"
            WADDeviceLog.shared.log("metrickit.exits", summary)
            if let peak = payload.memoryMetrics?.peakMemoryUsage {
                WADDeviceLog.shared.log("metrickit.mem", "picco memoria \(peak)")
            }
        }
    }

    /// Lo stack JSON di MetricKit supera il limite per-evento del devlog:
    /// lo spezzo in chunk numerati, si riassembla lato Mac quando serve.
    private static func shipStack(_ tree: MXCallStackTree, kind: String) {
        guard let json = String(data: tree.jsonRepresentation(), encoding: .utf8) else { return }
        let id = String(UUID().uuidString.prefix(8))
        let chunkSize = 1700
        let chunks = stride(from: 0, to: json.count, by: chunkSize).map { offset -> String in
            let start = json.index(json.startIndex, offsetBy: offset)
            let end = json.index(start, offsetBy: chunkSize, limitedBy: json.endIndex) ?? json.endIndex
            return String(json[start..<end])
        }
        for (index, chunk) in chunks.enumerated() {
            WADDeviceLog.shared.log("metrickit.stack", "\(kind) \(id) [\(index + 1)/\(chunks.count)] \(chunk)")
        }
    }
}
