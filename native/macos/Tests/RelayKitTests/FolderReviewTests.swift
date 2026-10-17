import XCTest
@testable import RelayKit

final class FolderReviewTests: XCTestCase {
    private func catalog(id: Int = 1, name: String = "Show", episodes: [EpisodeCandidate]) -> TVSeriesCatalog {
        TVSeriesCatalog(title: CatalogTitle(id: id, title: nil, name: name), episodes: episodes)
    }
    private func episode(_ id: Int = 10, title: String = "Arrival", season: Int = 1, number: Int = 2) -> EpisodeCandidate {
        EpisodeCandidate(id: id, name: title, seasonNumber: season, episodeNumber: number)
    }
    func testUniqueExactMatchProposesCanonicalIdentity() {
        let identity = FolderReview.suggestion(for: " Arrival! ", catalogs: [catalog(episodes: [episode()])], evidence: [:])
        XCTAssertEqual(identity?.title, "Show")
        XCTAssertEqual(identity?.season, 1)
        XCTAssertEqual(identity?.episode, 2)
        XCTAssertEqual(identity?.tmdbId, 1)
        XCTAssertNil(FolderReview.suggestion(for: "Arriv", catalogs: [catalog(episodes: [episode()])], evidence: [:]))
    }
    func testCommonTitlesAcrossShowsOrSeasonsRemainUnresolved() {
        XCTAssertNil(FolderReview.suggestion(for: "Arrival", catalogs: [catalog(episodes: [episode()]), catalog(id: 2, name: "Another Show", episodes: [episode(20)])], evidence: [:]))
        XCTAssertNil(FolderReview.suggestion(for: "Arrival", catalogs: [catalog(episodes: [episode(), episode(11, season: 2)])], evidence: [:]))
    }
    func testNumberingDisagreementPreventsFolderProposal() {
        let record = DiscoveryEvidence(source: .tvmaze, recordID: "external", title: "Show", episode: DiscoveredEpisode(title: "Arrival", season: 1, number: 3))
        XCTAssertNil(FolderReview.suggestion(for: "Arrival", catalogs: [catalog(episodes: [episode()])], evidence: [1: [record]]))
    }
    func testShowThenNumericSeasonAndEpisodeOrderWithUnknownsLast() {
        func identity(_ title: String, _ season: Int?, _ episode: Int?) -> MediaIdentity {
            var value = MediaIdentity(); value.kind = "tv"; value.title = title; value.season = season; value.episode = episode
            return value
        }
        let items = [identity("Zebra", 1, 1), identity("Alpha", 2, 1), identity("Alpha", 1, 10), identity("Alpha", nil, nil), identity("", nil, nil), identity("Alpha", 0, 1), identity("Alpha", 1, 2)]
        let sorted = items.enumerated().sorted {
            FolderReview.precedes(identity: $0.element, filename: "File \($0.offset)", id: "\($0.offset)", identity: $1.element, filename: "File \($1.offset)", id: "\($1.offset)")
        }.map(\.offset)
        XCTAssertEqual(sorted, [5, 6, 2, 1, 3, 0, 4])
    }
    func testNaturalFilenameOrderAndStableTieBreak() {
        let unknown = MediaIdentity()
        XCTAssertTrue(FolderReview.precedes(identity: unknown, filename: "Video 2.mp4", id: "b", identity: unknown, filename: "Video 10.mp4", id: "a"))
        XCTAssertTrue(FolderReview.precedes(identity: unknown, filename: "Same.mp4", id: "a", identity: unknown, filename: "Same.mp4", id: "b"))
    }
    func testMissingNumbersAreNotDisplayedAsSpecials() {
        var identity = MediaIdentity(); identity.kind = "tv"; identity.title = "Show"
        XCTAssertTrue(identity.display.contains("S?E?"))
        identity.season = 0; identity.episode = 0
        XCTAssertTrue(identity.display.contains("S0E0"))
    }
}
