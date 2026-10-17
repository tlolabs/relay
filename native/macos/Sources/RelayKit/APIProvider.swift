import Foundation

public enum APIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case tmdb = "TMDB", trakt = "Trakt", omdb = "OMDb", tvmaze = "TVmaze", tvdb = "TheTVDB", brave = "Brave Search", plex = "Plex"
    public var id: String { rawValue }
    public var policy: APIUsagePolicy {
        switch self {
        case .tmdb: return .init(daily: 5000, monthly: 50000, interval: 0.3, published: "Dynamic ceiling around 40/sec; Relay uses at most 3.3/sec", documentation: "https://developer.themoviedb.org/docs/rate-limiting")
        case .trakt: return .init(daily: 3000, monthly: 30000, interval: 1.1, published: "Standard GET: 500 per 5 minutes; Relay uses less than 1/sec", documentation: "https://developer.trakt.tv/docs/rate-limiting")
        case .omdb: return .init(daily: 900, monthly: 20000, interval: 1.1, published: "Free: 1,000/day; Relay stops at 900 per day and rolling 24 hours", documentation: "https://www.omdbapi.com/apikey.aspx")
        case .tvmaze: return .init(daily: 3000, monthly: 30000, interval: 1.1, published: "At least 20 per 10 seconds per IP; Relay uses less than 1/sec", documentation: "https://www.tvmaze.com/api#rate-limiting")
        case .tvdb: return .init(daily: 3000, monthly: 30000, interval: 1.1, published: "No fixed quota published in the API licensing page; conservative Relay budget", documentation: "https://www.thetvdb.com/api-information")
        case .brave: return .init(daily: 100, monthly: 900, interval: 1.1, published: "$5 monthly Search credits at $5/1,000; Relay stops at 900/month and rolling 31 days", documentation: "https://api-dashboard.search.brave.com/app/plans")
        case .plex: return .init(daily: 20000, monthly: 200000, interval: 0.2, published: "Personal server; no metered metadata API charge. Relay still enforces local budgets.", documentation: "https://developer.plex.tv/")
        }
    }
}

public struct APIUsagePolicy: Sendable {
    public var daily: Int
    public var monthly: Int
    public var interval: TimeInterval
    public var published: String
    public var documentation: String
}

public struct APIUsageCounters: Codable, Sendable {
    public var requests = 0
    public var successes = 0
    public var failures = 0
    public var cacheHits = 0
    public var blocked = 0
}

public struct APIConnectionCheck: Codable, Sendable {
    public var checkedAt: Date
    public var passed: Bool
    public var message: String
    public init(passed: Bool, message: String, checkedAt: Date = Date()) {
        self.passed = passed; self.message = message; self.checkedAt = checkedAt
    }
}

public struct APIUsageSnapshot: Sendable, Identifiable {
    public var provider: APIProvider
    public var today: APIUsageCounters
    public var monthRequests: Int
    public var rollingDayRequests: Int
    public var rollingMonthRequests: Int
    public var lifetime: APIUsageCounters
    public var lastRequest: Date?
    public var lastHTTPStatus: Int?
    public var cooldownUntil: Date?
    public var remoteRemaining: Int?
    public var remoteReset: Date?
    public var remoteWindows: [APIRateWindow]?
    public var check: APIConnectionCheck?
    public var id: APIProvider { provider }
}

public struct APIRateWindow: Codable, Sendable {
    public var limit: Int
    public var remaining: Int
    public var seconds: Int?
    public var resetsAt: Date
}

extension MetadataSource {
    public var apiProvider: APIProvider? {
        switch self {
        case .trakt: return .trakt
        case .omdb: return .omdb
        case .tvmaze: return .tvmaze
        case .tvdb: return .tvdb
        case .imdb: return nil
        }
    }
}
