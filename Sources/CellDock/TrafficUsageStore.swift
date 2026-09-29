import Foundation

/// Cumulative cellular traffic for one module. When the module firmware keeps
/// its own counters (AT+QGDCNT) those take precedence — they are 64-bit and
/// survive USB re-enumeration. Otherwise the store accumulates host-side
/// deltas of the ECM interface's byte counters, which are 32-bit on macOS:
/// delta arithmetic modulo 2^32 survives counter wrap as long as samples are
/// taken well inside a wrap (~4 GB), and an interface change only resets the
/// baseline, never the persisted total.
struct TrafficUsage: Equatable, Codable {
    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0

    var totalBytes: UInt64 {
        receivedBytes &+ sentBytes
    }
}

@MainActor
final class TrafficUsageStore {
    private struct PersistentRecord: Codable {
        var usageByModuleIMEI: [String: TrafficUsage] = [:]
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var record: PersistentRecord
    private var lastCountersByModuleIMEI: [String: NetworkInterfaceByteCounters] = [:]
    private var lastInterfaceByModuleIMEI: [String: String] = [:]
    /// Modules whose totals are authoritative from the module side; host
    /// accumulation is suspended for them until the module stops reporting.
    private var moduleReportedIMEIs: Set<String> = []

    init(fileManager: FileManager = .default) {
        let directory = AppDataDirectory.userApplicationSupport(fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("traffic-usage.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode(PersistentRecord.self, from: data) {
            record = decoded
        } else {
            record = PersistentRecord()
        }
    }

    var usageByModuleIMEI: [String: TrafficUsage] {
        record.usageByModuleIMEI
    }

    func usage(forModuleIMEI imei: String) -> TrafficUsage {
        record.usageByModuleIMEI[imei] ?? TrafficUsage()
    }

    /// Samples the host-side interface counters for one module. A nil or
    /// mismatched sample only drops the baseline; it never adds traffic.
    func accumulate(
        counters: NetworkInterfaceByteCounters?,
        interfaceName: String?,
        forModuleIMEI imei: String
    ) {
        guard !moduleReportedIMEIs.contains(imei) else { return }
        defer { persistIfNeeded() }
        guard let interfaceName,
              let counters,
              lastInterfaceByModuleIMEI[imei] == interfaceName,
              let previous = lastCountersByModuleIMEI[imei] else {
            lastInterfaceByModuleIMEI[imei] = interfaceName
            lastCountersByModuleIMEI[imei] = counters
            return
        }
        lastCountersByModuleIMEI[imei] = counters
        let received = counterDelta(previous: previous.received, current: counters.received)
        let sent = counterDelta(previous: previous.sent, current: counters.sent)
        guard received > 0 || sent > 0 else { return }
        var usage = record.usageByModuleIMEI[imei] ?? TrafficUsage()
        usage.receivedBytes &+= received
        usage.sentBytes &+= sent
        record.usageByModuleIMEI[imei] = usage
    }

    /// Records module-authoritative counters (AT+QGDCNT). The stored total is
    /// replaced, not added to: QGDCNT is cumulative for the PDP context.
    func setModuleUsage(_ usage: TrafficUsage, forModuleIMEI imei: String) {
        moduleReportedIMEIs.insert(imei)
        lastCountersByModuleIMEI[imei] = nil
        lastInterfaceByModuleIMEI[imei] = nil
        if record.usageByModuleIMEI[imei] != usage {
            record.usageByModuleIMEI[imei] = usage
            persistIfNeeded()
        }
    }

    /// Manual reset from the traffic panel.
    func reset(forModuleIMEI imei: String) {
        moduleReportedIMEIs.remove(imei)
        lastCountersByModuleIMEI[imei] = nil
        lastInterfaceByModuleIMEI[imei] = nil
        record.usageByModuleIMEI[imei] = TrafficUsage()
        persistIfNeeded()
    }

    private func persistIfNeeded() {
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 32-bit counter delta that treats wrap as forward motion: unsigned
    /// subtraction modulo 2^32 is exactly the number of bytes transferred
    /// when fewer than one full wrap happened between the samples.
    private func counterDelta(previous: UInt32, current: UInt32) -> UInt64 {
        guard current != previous else { return 0 }
        return UInt64(current &- previous)
    }
}
