import XCTest
@testable import RelayKit

final class MatchConfidenceTests: XCTestCase {
    private func catalog(id: Int = 1, episodes: [EpisodeCandidate]? = nil) -> TVSeriesCatalog {
        TVSeriesCatalog(title: CatalogTitle(id: id, name: "Show \(id)"), episodes: episodes ?? [EpisodeCandidate(id: id * 10, name: "Arrival", seasonNumber: 1, episodeNumber: 2)])
    }
    private func evidence(_ source: MetadataSource, number: Int = 2, title: String = "Arrival") -> DiscoveryEvidence {
        DiscoveryEvidence(source: source, recordID: "record", title: "Show 1", episode: DiscoveredEpisode(title: title, season: 1, number: number))
    }
    func testUniqueExactTitleNeedsCorroborationForHighConfidence() {
        let single = MatchConfidence.tv(clue: "Arrival", catalogs: [catalog()], evidence: [:])
        XCTAssertEqual(single.score, 60)
        XCTAssertEqual(single.level, "Medium")
        let corroborated = MatchConfidence.tv(clue: "Arrival", catalogs: [catalog()], evidence: [1: [evidence(.trakt), evidence(.imdb), evidence(.tvmaze)]])
        XCTAssertEqual(corroborated.score, 70)
        XCTAssertEqual(corroborated.level, "Medium")
        XCTAssertTrue(corroborated.explanation.contains("not a probability"))
    }
    func testDuplicateRecordsAndOtherFilesDoNotInflateConfidence() {
        let record = evidence(.trakt)
        let one = MatchConfidence.tv(clue: "Arrival", catalogs: [catalog()], evidence: [1: [record]])
        let duplicates = MatchConfidence.tv(clue: "Arrival", catalogs: [catalog(), catalog()], evidence: [1: Array(repeating: record, count: 100) + [evidence(.imdb, title: "Other Episode")]])
        XCTAssertEqual(one.score, 70)
        XCTAssertEqual(duplicates.score, one.score)
    }
    func testAmbiguousPilotAndConflictingNumberingStayLow() {
        let ambiguous = MatchConfidence.tv(clue: "Arrival", catalogs: [catalog(), catalog(id: 2)], evidence: [1: [evidence(.trakt)]])
        XCTAssertEqual(ambiguous.score, 30)
        XCTAssertNil(ambiguous.candidate)
        XCTAssertEqual(MatchConfidence.tv(clue: "Arrival", catalogs: [catalog()], evidence: [1: [evidence(.trakt, number: 3), evidence(.imdb)]]).score, 25)
        XCTAssertEqual(MatchConfidence.tv(clue: "No Such Episode", catalogs: [catalog()], evidence: [:]).score, 0)
        XCTAssertEqual(MatchConfidence.tv(clue: "Arrival", catalogs: [catalog()], evidence: [:], showID: 2).score, 0)
    }
    func testOptionalIncompleteChecksDoNotReduceCatalogAgreement() {
        let score = MatchConfidence.tv(clue: "Arrival", catalogs: [catalog()], evidence: [1: [evidence(.trakt), evidence(.imdb), evidence(.tvmaze)]], incomplete: true)
        XCTAssertEqual(score.score, 70)
        XCTAssertTrue(score.explanation.contains("incomplete") || score.explanation.contains("failed"))
    }
    func testMovieRemakesAndYearConflictsLowerConfidence() {
        let original = CatalogTitle(id: 1, title: "Movie", releaseDate: "2020-01-01")
        let remake = CatalogTitle(id: 2, title: "Movie", releaseDate: "2025-01-01")
        let matching = DiscoveryEvidence(source: .omdb, recordID: "tt1", kind: "movie", title: "Movie", year: 2020)
        let wrongYear = DiscoveryEvidence(source: .trakt, recordID: "2", kind: "movie", title: "Movie", year: 2021)
        XCTAssertEqual(MatchConfidence.movie(title: original, query: "Movie", candidates: [original], evidence: [matching]).score, 60)
        XCTAssertEqual(MatchConfidence.movie(title: original, query: "Movie", candidates: [original, remake], evidence: [matching]).score, 40)
        XCTAssertEqual(MatchConfidence.movie(title: original, query: "Movie", candidates: [original], evidence: [matching, wrongYear]).score, 25)
    }
}
