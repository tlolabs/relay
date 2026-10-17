import Foundation
import Darwin

private struct APIUsageRecord: Codable {
    var days: [String: APIUsageCounters] = [:]
    var hours: [String: Int] = [:]
    var lifetime = APIUsageCounters()
    var lastRequest: Date?
    var lastHTTPStatus: Int?
    var nextRequest: Date?
    var cooldown: Date?
    var remoteRemaining: Int?
    var remoteReset: Date?
    var remoteWindows: [APIRateWindow]?
    var check: APIConnectionCheck?
    var legacyImported = false
}
private struct APIUsageLedger: Codable {
    var version = 1
    var services: [String: APIUsageRecord] = [:]
}

/// A process-shared, fail-closed ledger. A reservation is written durably before
/// networking. Failed/cancelled attempts are never refunded. No keys or URLs enter it.
public actor APIUsageStore {
    public static let shared = APIUsageStore()
    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RELAY/api-usage.json")
    }
    private let file: URL?
    private let policies: [APIProvider: APIUsagePolicy]
    private let clock: @Sendable () -> Date
    private var memory = APIUsageLedger()
    public init(fileURL: URL? = APIUsageStore.defaultFile) {
        file = fileURL; policies = [:]; clock = { @Sendable in Date() }
    }
    init(testFile: URL?, policies: [APIProvider: APIUsagePolicy], clock: @escaping @Sendable () -> Date = { Date() }) {
        file = testFile; self.policies = policies; self.clock = clock
    }
    private func policy(_ source: APIProvider) -> APIUsagePolicy { policies[source] ?? source.policy }
    private func day(_ date: Date) -> String { String(ISO8601DateFormatter().string(from: date).prefix(10)) }
    private func hour(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 3600)) }
    private func rolling(_ record: APIUsageRecord, since: Date) -> Int {
        // Include the entire overlapping hour: this is deliberately conservative.
        record.hours.reduce(0) { $0 + ((Int($1.key) ?? 0) >= hour(since) ? $1.value : 0) }
    }
    private func update(_ record: inout APIUsageRecord, at now: Date, _ change: (inout APIUsageCounters) -> Void) {
        var today = record.days[day(now), default: APIUsageCounters()]
        change(&today); record.days[day(now)] = today; change(&record.lifetime)
    }
    private func transaction<T>(_ work: (inout APIUsageLedger) throws -> T) throws -> T {
        guard let file else { return try work(&memory) }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = Darwin.open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw RelayFailure.message("Cannot lock API usage counters") }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw RelayFailure.message("Cannot lock API usage counters") }
            defer { flock(descriptor, LOCK_UN) }
            var ledger = APIUsageLedger()
            if manager.fileExists(atPath: file.path) {
                ledger = try JSONDecoder().decode(APIUsageLedger.self, from: Data(contentsOf: file))
                guard ledger.version == 1 else { throw RelayFailure.message("Unsupported API usage ledger version") }
            }
            let result = try work(&ledger)
            try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return result
        } catch {
            throw RelayFailure.message("API usage counters could not be read or saved. Network requests are stopped to protect your limits; check the usage file in Application Support/RELAY.")
        }
    }
    public func reserve(_ source: APIProvider) async throws {
        while true {
            try Task.checkCancellation()
            let now = clock(), limit = policy(source)
            let outcome: (TimeInterval, String?) = try transaction { ledger in
                var record = ledger.services[source.rawValue, default: APIUsageRecord()]
                let today = record.days[day(now), default: APIUsageCounters()].requests
                let month = record.days.filter { $0.key.hasPrefix(String(day(now).prefix(7))) }.values.reduce(0) { $0 + $1.requests }
                var reason: String?
                if let last = record.lastRequest, last.timeIntervalSince(now) > 120 { reason = "The Mac's clock moved backwards. Restore the correct time before making API requests." }
                else if today >= limit.daily || rolling(record, since: now.addingTimeInterval(-86400)) >= limit.daily { reason = "\(source.rawValue) reached Relay's hard daily/rolling-24-hour cap (\(limit.daily)). Other sources remain available." }
                else if month >= limit.monthly || (source == .brave && rolling(record, since: now.addingTimeInterval(-31 * 86400)) >= limit.monthly) { reason = "\(source.rawValue) reached Relay's hard monthly cap (\(limit.monthly)). Brave also uses a rolling 31-day cap." }
                else if let until = record.cooldown, until > now { reason = "\(source.rawValue) is paused until \(until.formatted(date: .abbreviated, time: .standard)) after a provider rate limit." }
                if let reason {
                    update(&record, at: now) { $0.blocked += 1 }; ledger.services[source.rawValue] = record
                    return (0, reason)
                }
                if let next = record.nextRequest, next > now { return (next.timeIntervalSince(now), nil) }
                update(&record, at: now) { $0.requests += 1 }
                record.hours[String(hour(now)), default: 0] += 1
                record.hours = record.hours.filter { (Int($0.key) ?? 0) >= hour(now.addingTimeInterval(-32 * 86400)) }
                record.days = record.days.filter { $0.key >= day(now.addingTimeInterval(-65 * 86400)) }
                record.lastRequest = now; record.nextRequest = now.addingTimeInterval(limit.interval)
                ledger.services[source.rawValue] = record
                return (0, nil)
            }
            if let message = outcome.1 { throw RelayFailure.message(message) }
            if outcome.0 == 0 { return }
            try await Task.sleep(for: .seconds(min(outcome.0, 1)))
            // Recheck after every suspension; concurrent clients cannot reserve the same slot.
        }
    }
    public func cacheHit(_ source: APIProvider) throws {
        let now = clock()
        try transaction { ledger in
            var record = ledger.services[source.rawValue, default: APIUsageRecord()]
            update(&record, at: now) { $0.cacheHits += 1 }; ledger.services[source.rawValue] = record
        }
    }
    public func completed(_ source: APIProvider, response: HTTPURLResponse?) throws {
        let now = clock()
        try transaction { ledger in
            var record = ledger.services[source.rawValue, default: APIUsageRecord()]
            let status = response?.statusCode
            update(&record, at: now) { if let status, (200..<400).contains(status) { $0.successes += 1 } else { $0.failures += 1 } }
            record.lastHTTPStatus = status
            if let response {
                if status == 429 {
                    record.cooldown = max(record.cooldown ?? now, Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now) ?? now.addingTimeInterval(60))
                }
                if let raw = response.value(forHTTPHeaderField: "X-Ratelimit"), let data = raw.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    record.remoteRemaining = object["remaining"] as? Int
                    record.remoteReset = (object["until"] as? String).flatMap { Self.isoDate($0) }
                    if record.remoteRemaining == 0, let until = record.remoteReset { record.cooldown = max(record.cooldown ?? now, until) }
                }
                let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?.split(separator: ",", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
                let resets = response.value(forHTTPHeaderField: "X-RateLimit-Reset")?.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
                let limits = response.value(forHTTPHeaderField: "X-RateLimit-Limit")?.split(separator: ",", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
                let windows = response.value(forHTTPHeaderField: "X-RateLimit-Policy")?.split(separator: ",", omittingEmptySubsequences: false).map { part -> Int? in
                    guard let raw = part.components(separatedBy: "w=").last else { return nil }
                    return Int(raw.trimmingCharacters(in: .whitespaces))
                }
                if let remaining, let resets, remaining.count == resets.count {
                    var recorded: [APIRateWindow] = []
                    for index in remaining.indices {
                        guard let value = remaining[index], value >= 0, let reset = resets[index], reset.isFinite, reset >= 0 else { continue }
                        let limit = limits.flatMap { index < $0.count ? $0[index] : nil }
                        // Brave explicitly documents a zero monthly limit as unlimited.
                        let unlimited = source == .brave && limit == 0
                        let until = source != .brave && reset > 1_000_000_000 ? Date(timeIntervalSince1970: reset) : now.addingTimeInterval(reset)
                        if let limit { recorded.append(APIRateWindow(limit: limit, remaining: value, seconds: windows.flatMap { index < $0.count ? $0[index] : nil }, resetsAt: until)) }
                        if value == 0 && !unlimited { record.cooldown = max(record.cooldown ?? now, until) }
                    }
                    record.remoteWindows = recorded
                    let measured = recorded.filter { $0.limit > 0 }.max { ($0.seconds ?? 0) < ($1.seconds ?? 0) }
                    record.remoteRemaining = measured?.remaining
                    record.remoteReset = measured?.resetsAt
                }
            }
            ledger.services[source.rawValue] = record
        }
    }
    public func pause(_ source: APIProvider, until: Date) throws {
        try transaction { ledger in
            var record = ledger.services[source.rawValue, default: APIUsageRecord()]
            record.cooldown = max(record.cooldown ?? until, until); ledger.services[source.rawValue] = record
        }
    }
    public func checked(_ source: APIProvider, result: APIConnectionCheck) throws {
        try transaction { ledger in
            var record = ledger.services[source.rawValue, default: APIUsageRecord()]
            record.check = result; ledger.services[source.rawValue] = record
        }
    }
    public func snapshots() throws -> [APIUsageSnapshot] {
        let now = clock()
        return try transaction { ledger in APIProvider.allCases.map { source in
            let record = ledger.services[source.rawValue, default: APIUsageRecord()]
            return APIUsageSnapshot(provider: source, today: record.days[day(now), default: APIUsageCounters()], monthRequests: record.days.filter { $0.key.hasPrefix(String(day(now).prefix(7))) }.values.reduce(0) { $0 + $1.requests }, rollingDayRequests: rolling(record, since: now.addingTimeInterval(-86400)), rollingMonthRequests: rolling(record, since: now.addingTimeInterval(-31 * 86400)), lifetime: record.lifetime, lastRequest: record.lastRequest, lastHTTPStatus: record.lastHTTPStatus, cooldownUntil: record.cooldown.flatMap { $0 > now ? $0 : nil }, remoteRemaining: record.remoteRemaining, remoteReset: record.remoteReset, remoteWindows: record.remoteWindows, check: record.check)
        } }
    }
    func importLegacyOMDbBudget(cache: URL?) throws {
        guard let cache = cache ?? file?.deletingLastPathComponent().appendingPathComponent("catalog-cache") else { return }
        let now = clock()
        try transaction { ledger in
            var record = ledger.services[APIProvider.omdb.rawValue, default: APIUsageRecord()]
            guard !record.legacyImported else { return }
            for date in [now, now.addingTimeInterval(-86400)] {
                let key = day(date), url = cache.appendingPathComponent("omdb-budget-\(key).json")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let old = try JSONDecoder().decode(Int.self, from: Data(contentsOf: url))
                let extra = max(0, old)
                record.days[key, default: APIUsageCounters()].requests += extra
                record.lifetime.requests += extra; record.hours[String(hour(now)), default: 0] += extra
            }
            record.legacyImported = true; ledger.services[APIProvider.omdb.rawValue] = record
        }
    }
    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: string)
    }
    static func retryDate(_ raw: String?, now: Date) -> Date? {
        guard let raw else { return nil }
        if let seconds = Double(raw), seconds.isFinite { return now.addingTimeInterval(max(1, seconds)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max($0, now.addingTimeInterval(1)) }
    }
}
