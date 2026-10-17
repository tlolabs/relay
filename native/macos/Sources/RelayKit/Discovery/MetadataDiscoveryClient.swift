import Foundation

public actor MetadataDiscoveryClient {
    let http: ProviderHTTP
    var tvdbSession: (key: String, token: String, expires: Date)?
    public init(session: URLSession? = nil, usage: APIUsageStore = .shared) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        http = ProviderHTTP(session: session ?? URLSession(configuration: configuration), usage: usage)
    }

    public func discover(titles: [String], kind: String, seeds: [DiscoverySeed], credentials: DiscoveryCredentials, cache: URL?, enabled: Set<MetadataSource> = Set(MetadataSource.allCases), progress: @Sendable (DiscoveryReport) -> Void = { _ in }) async throws -> DiscoveryReport {
        let clues = EpisodeClues.unique(titles)
        async let traktResult = enabled.contains(.trakt) ? trakt(clues: clues, kind: kind, key: credentials.trakt, cache: cache) : disabled(.trakt)
        async let omdbResult = enabled.contains(.omdb) ? omdb(clues: clues, kind: kind, key: credentials.omdb, cache: cache) : disabled(.omdb)
        let global = await [traktResult, omdbResult]
        try Task.checkCancellation()
        let globalEvidence = global.flatMap(\.evidence)
        progress(DiscoveryReport(evidence: globalEvidence, statuses: global.flatMap(\.statuses)))
        let allSeeds = Array(Set(seeds + globalEvidence.map { DiscoverySeed(title: $0.title, year: $0.year, ids: $0.ids) }))
        async let mazeResult = enabled.contains(.tvmaze) ? tvmaze(clues: clues, kind: kind, seeds: allSeeds, cache: cache) : disabled(.tvmaze)
        async let tvdbResult = enabled.contains(.tvdb) ? tvdb(clues: clues, kind: kind, seeds: allSeeds, key: credentials.tvdb, cache: cache) : disabled(.tvdb)
        let reports = await [mazeResult, tvdbResult] + global
        try Task.checkCancellation()
        return DiscoveryReport(evidence: Array(Set(reports.flatMap(\.evidence))), statuses: reports.flatMap(\.statuses).sorted { $0.source.rawValue < $1.source.rawValue })
    }
    func disabled(_ source: MetadataSource) -> DiscoveryReport {
        DiscoveryReport(statuses: [ProviderStatus(source: source, message: "Disabled in Settings", incomplete: false)])
    }
    func report(_ source: MetadataSource, _ records: [DiscoveryEvidence], _ warning: String? = nil) -> DiscoveryReport {
        DiscoveryReport(evidence: Array(Set(records)), statuses: [ProviderStatus(source: source, message: warning ?? "\(Set(records).count) matching records", incomplete: warning != nil)])
    }
    func missing(_ source: MetadataSource) -> DiscoveryReport {
        DiscoveryReport(statuses: [ProviderStatus(source: source, message: "Add a free API key in Settings", incomplete: false)])
    }
    func failure(_ error: Error) -> String {
        if error is CancellationError || Task.isCancelled { return "Search cancelled" }
        if let failure = error as? RelayFailure { return failure.localizedDescription }
        return "Unexpected provider response; other sources remain available"
    }
    func query(_ items: [String: String]) -> [URLQueryItem] { items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    func exact(_ name: String, _ clues: [String]) -> Bool { clues.contains { EpisodeClues.normalized($0) == EpisodeClues.normalized(name) } }
}
