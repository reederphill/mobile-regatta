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

// #241: the lobby, profile, store, analytics, connectivity and deletion fakes, on the same seam.

@Suite struct LobbyServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await LobbyServiceContract().run { Fixtures.lobby($0) }
    }
}

@Suite struct ProfileServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await ProfileServiceContract().run { Fixtures.profile($0) }
    }
}

@Suite struct StoreServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await StoreServiceContract().run { Fixtures.store($0) }
    }
}

@Suite struct AnalyticsTransportContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await AnalyticsTransportContract().run { Fixtures.analytics($0) }
    }
}

@Suite struct ConnectivityServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await ConnectivityServiceContract().run { Fixtures.connectivity($0) }
    }
}

@Suite struct DataDeletionServiceContractTests {
    @Test func scriptedFakePassesTheSuite() async throws {
        try await DataDeletionServiceContract().run { Fixtures.deletion($0) }
    }
}
