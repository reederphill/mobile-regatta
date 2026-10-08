import RegattaCore
import RegattaProtocol
import RegattaServiceClient
import RegattaServices
import Testing

/// Every case of the service enums survives its wire form (#143), including the ones no contract suite reaches
/// (a livery not owned, an attestation failure, every lobby error).
@Suite struct WireMappingTests {
    @Test func everyEnumCaseSurvivesItsWireForm() {
        let refusals: [QueueRefusal] = [.notSignedIn, .termsNotAccepted, .multiplayerRestricted, .cooldown(secondsRemaining: 7),
                                        .suspended(until: nil), .suspended(until: 1_800_000_000), .attestationFailed, .updateRequired]
        for refusal in refusals { #expect(QueueRefusal(wire: refusal.wire) == refusal) }
        let states: [QueueState] = [.idle, .unavailable(.attestationFailed), .queued(QueuedStatus(queuedPlayers: 4, secondsToLock: -1)), .fleetLocked]
        for state in states { #expect(QueueState(wire: state.wire) == state) }
        let problems: [LiveryProblem] = [.sailNumber, .slotCount, .colour, .unknownDesign, .notOwned]
        for problem in problems { #expect(LiveryProblem(wire: problem.wire) == problem) }
        #expect(Set(problems.map(\.wire)) == Set(WireLiveryProblem.allCases))
        let closures: [LobbyClosure] = [.notSignedIn, .termsNotAccepted, .communicationRestricted, .racing]
        let errors: [LobbyError] = closures.map(LobbyError.closed) + [
            .freeTextLocked, .empty, .tooLong(limit: 200), .rateLimited(retryAfterSeconds: 3), .muted(until: 1_790_086_400), .banned,
            .unknownMessage, .notReportable, .cannotBlockSelf,
        ]
        for error in errors { #expect(LobbyError(wire: error.wire) == error) }
        for quick in QuickChat.allCases { #expect(QuickChat(wire: quick.wire) == quick) }
        for reason in [RaceReportReason.unsportingConduct, .suspectedCheating] { #expect(RaceReportReason(wire: reason.wire) == reason) }
        for data in OnlineData.allCases { #expect(OnlineData(wire: data.wire) == data) }
        let statuses: [TermsStatus] = [.accepted(TermsVersion(2)), .needsAcceptance(current: TermsVersion(3), lastAccepted: nil),
                                       .needsAcceptance(current: TermsVersion(3), lastAccepted: TermsVersion(2))]
        for status in statuses { #expect(TermsStatus(wire: status.wire) == status) }
        for standing: ChatStanding in [.clear, .muted(until: 9, isAutomatic: false), .banned] {
            let state = LobbyState(access: .closed(.racing), canPostFreeText: false, standing: standing)
            #expect(LobbyState(wire: state.wire) == state)
        }
        let open = LobbyState(access: .open, canPostFreeText: true)
        #expect(LobbyState(wire: open.wire) == open)
        let notSent = LobbyMessage(id: MessageID("m"), kind: .post(LobbyPost(author: Fixtures.wren, body: .text("x"), delivery: .notSent)))
        #expect(LobbyMessage(wire: notSent.wire) == notSent)
        let unrated = RatingChange(raceID: RaceID("r"), outcome: .unrated)
        #expect(RatingChange(wire: unrated.wire) == unrated)
        for suspension in [nil, RacingSuspension(until: nil), RacingSuspension(until: 5)] {
            var profile = Fixtures.profile(races: 60, wins: 9, suspension: suspension)
            profile.progress = EarnedProgress(earned: [Fixtures.earned10, Fixtures.earned50], next: nil)
            #expect(Profile(wire: profile.wire) == profile)
        }
        let batch = AnalyticsBatch(installID: InstallID("i"), events: [AnalyticsEvent(
            sequence: 1, name: .drop, time: 2, properties: ["é": .int(-3), "a": .double(0.5), "Z": .string("s"), "b": .bool(true)])])
        #expect(batch.wire.events[0].properties.map(\.key) == ["Z", "a", "b", "é"])
        #expect(AnalyticsBatch(wire: batch.wire) == batch)
    }
}
