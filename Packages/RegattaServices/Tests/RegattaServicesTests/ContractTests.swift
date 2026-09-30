import RegattaServiceContracts
import Testing

// Each service's scripted fake, held to its contract suite (#109). Remote runner (#143) and the real services
// run the same suites.

@Suite struct IdentityServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await IdentityServiceContract().run { Fixtures.identity($0) }
    }
}

@Suite struct TermsServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await TermsServiceContract().run { Fixtures.terms($0) }
    }
}

@Suite struct QueueServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await QueueServiceContract().run { Fixtures.queue($0) }
    }
}

@Suite struct RaceSessionServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await RaceSessionServiceContract().run { Fixtures.raceSession($0) }
    }
}
