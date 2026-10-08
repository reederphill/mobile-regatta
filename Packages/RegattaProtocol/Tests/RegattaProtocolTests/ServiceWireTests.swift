import RegattaCore
@testable import RegattaProtocol
import Testing

/// The service messages (#143) beyond the round trip (`RoundTripTests.everyMessageRoundTrips` covers each type):
/// one encoding per message, unknown codes and set reserved bits rejected, the race protocol's codes untouched.
@Suite struct ServiceWireTests {
    static func header(_ type: MessageType) -> [UInt8] { [type.rawValue, 0, 0, 0, 0, 0, 0, 0, 0] }

    static func decode(_ type: MessageType, _ body: [UInt8]) throws -> Message { try Frame(decoding: header(type) + body).message }

    static func encode(_ message: Message) throws -> [UInt8] { Array(try Frame(seq: 0, tick: 0, message: message).encoded().dropFirst(9)) }

    @Test func serviceCodesStartAt64AndKeepTheirDirection() {
        let service = MessageType.allCases.filter { $0.rawValue >= 64 }
        #expect(MessageType.allCases.filter { $0.rawValue >= 32 } == service)
        #expect(service.map(\.rawValue) == Array(64...74) + Array(80...89))
        for type in service {
            #expect((type.direction == .clientToServer) == (type.rawValue < 80))
            #expect(type.stream == .other)
        }
        #expect(wireProtocolVersion == 1)
    }

    /// A request's id leads its body, a varint; the reply echoes it, and `replyID` reads it.
    @Test func repliesEchoTheirRequestsID() throws {
        #expect(try Self.encode(.identityRequest(ServiceRequest(id: 300, call: .signIn))) == [0xAC, 0x02, 4])
        #expect(try Self.encode(.streamNext(StreamNext(id: 7, stream: 5))) == [7, 5])
        #expect(try Self.decode(.identityReply, [0xAC, 0x02, 3]).replyID == 300)
        #expect(try Self.decode(.streamEnd, [9]).replyID == 9)
        #expect(Message.identityRequest(ServiceRequest(id: 1, call: .state)).replyID == nil)
        #expect(Message.ping(Ping(clientTime: 1)).replyID == nil)
        // An id is a uint32: one past it, and a long-form varint, are rejected.
        #expect(throws: WireError.invalidValue("id")) { try Self.decode(.streamEnd, [0x80, 0x80, 0x80, 0x80, 0x10]) }
        #expect(throws: WireError.invalidValue("id")) { try Self.decode(.streamEnd, [0x81, 0x00]) }
    }

    /// The session calls (#145): a code, then the call's fields; unknown codes are rejected.
    @Test func sessionMessagesEncodeTheirCodeThenFields() throws {
        #expect(try Self.encode(.sessionRequest(ServiceRequest(id: 1, call: .signOut))) == [1, 2])
        #expect(try Self.encode(.sessionReply(ServiceReply(id: 1, result: .refused(.sessionExpired)))) == [1, 1, 3])
        let player = WirePlayer(gamePlayerID: "G", alias: "A", isUnderage: false, isPersonalizedCommunicationRestricted: false,
                                isMultiplayerGamingRestricted: true)
        #expect(try Self.encode(.sessionRequest(ServiceRequest(id: 2, call: .resume(token: [7, 8], player: player))))
            == [2, 1, 2, 7, 8, 1, 0x47, 1, 0x41, 4])
        #expect(throws: WireError.invalidValue("sessionCall")) { try Self.decode(.sessionRequest, [0, 3]) }
        #expect(throws: WireError.invalidValue("sessionResult")) { try Self.decode(.sessionReply, [0, 3]) }
        #expect(throws: WireError.invalidValue("sessionRefusal")) { try Self.decode(.sessionReply, [0, 1, 5]) }
        #expect(try Self.decode(.sessionReply, [4, 2]).replyID == 4)
    }

    @Test func integersAreZigzagVarints() throws {
        let queued = Message.queueReply(ServiceReply(id: 0, result: .state(.queued(queuedPlayers: 3, secondsToLock: -1))))
        #expect(try Self.encode(queued) == [0, 0, 2, 6, 1])
        #expect(try Frame(decoding: Frame(seq: 0, tick: 0, message: queued).encoded()).message == queued)
        let extremes = Message.termsReply(ServiceReply(id: 0, result: .status(.needsAcceptance(current: .max, lastAccepted: .min))))
        #expect(try Frame(decoding: Frame(seq: 0, tick: 0, message: extremes).encoded()).message == extremes)
    }

    @Test func unknownCallAndResultCodesAreRejected() throws {
        #expect(throws: WireError.invalidValue("identityCall")) { try Self.decode(.identityRequest, [0, 5]) }
        #expect(throws: WireError.invalidValue("identityResult")) { try Self.decode(.identityReply, [0, 4]) }
        #expect(throws: WireError.invalidValue("termsCall")) { try Self.decode(.termsRequest, [0, 2]) }
        #expect(throws: WireError.invalidValue("termsResult")) { try Self.decode(.termsReply, [0, 2]) }
        #expect(throws: WireError.invalidValue("queueCall")) { try Self.decode(.queueRequest, [0, 3]) }
        #expect(throws: WireError.invalidValue("queueResult")) { try Self.decode(.queueReply, [0, 5]) }
        #expect(throws: WireError.invalidValue("queueState")) { try Self.decode(.queueReply, [0, 0, 4]) }
        #expect(throws: WireError.invalidValue("refusal")) { try Self.decode(.queueReply, [0, 2, 7]) }
        #expect(throws: WireError.invalidValue("raceSessionCall")) { try Self.decode(.raceSessionRequest, [0, 5]) }
        #expect(throws: WireError.invalidValue("raceSessionResult")) { try Self.decode(.raceSessionReply, [0, 8]) }
        #expect(throws: WireError.invalidValue("lobbyCall")) { try Self.decode(.lobbyRequest, [0, 11]) }
        #expect(throws: WireError.invalidValue("quickChat")) { try Self.decode(.lobbyRequest, [0, 4, 4]) }
        #expect(throws: WireError.invalidValue("reason")) { try Self.decode(.lobbyRequest, [0, 10, 0, 1, 2]) }
        #expect(throws: WireError.invalidValue("lobbyResult")) { try Self.decode(.lobbyReply, [0, 9]) }
        #expect(throws: WireError.invalidValue("lobbyError")) { try Self.decode(.lobbyReply, [0, 8, 10]) }
        #expect(throws: WireError.invalidValue("closure")) { try Self.decode(.lobbyReply, [0, 8, 0, 4]) }
        #expect(throws: WireError.invalidValue("standing")) { try Self.decode(.lobbyReply, [0, 0, 0, 0, 3]) }
        #expect(throws: WireError.invalidValue("profileCall")) { try Self.decode(.profileRequest, [0, 2]) }
        #expect(throws: WireError.invalidValue("profileResult")) { try Self.decode(.profileReply, [0, 5]) }
        #expect(throws: WireError.invalidValue("liveryProblem")) { try Self.decode(.profileReply, [0, 3, 5]) }
        #expect(throws: WireError.invalidValue("analyticsResult")) { try Self.decode(.analyticsReply, [0, 3]) }
        #expect(throws: WireError.invalidValue("deletionCall")) { try Self.decode(.deletionRequest, [0, 2]) }
        #expect(throws: WireError.invalidValue("deletionResult")) { try Self.decode(.deletionReply, [0, 5]) }
        // The cancellation reason is the exception, as in `RaceCancelled`: a newer server's reason still arrives.
        #expect(try Self.decode(.raceSessionReply, [0, 3, 200]) == .raceSessionReply(ServiceReply(
            id: 0, result: .update(.cancelled(RaceCancelled.Reason(code: 200))))))
    }

    @Test func reservedBitsAndFlagsAreRejected() throws {
        // A player: id, alias, then three restriction flags; bit 3 and up are 0.
        _ = try Self.decode(.identityReply, [0, 0, 1, 1, 0x41, 1, 0x42, 0b111])
        #expect(throws: WireError.invalidValue("restrictions")) { try Self.decode(.identityReply, [0, 0, 1, 1, 0x41, 1, 0x42, 0b1000]) }
        #expect(throws: WireError.invalidValue("player")) { try Self.decode(.identityReply, [0, 0, 2]) }
        // A deletion plan's byte of data kinds: bit 7 is 0.
        _ = try Self.decode(.deletionReply, [0, 0, 0x7F, 1, 0])
        #expect(throws: WireError.invalidValue("deletes")) { try Self.decode(.deletionReply, [0, 0, 0x80, 1, 0]) }
        #expect(throws: WireError.invalidValue("anonymisesRaceLogs")) { try Self.decode(.deletionReply, [0, 0, 0, 2, 0]) }
        #expect(throws: WireError.invalidValue("suspension")) {
            try Self.decode(.profileReply, [0, 0, 0, 0, 0, 0, 0, 0, 3])
        }
    }

    /// The incident index's records keep the core's rules: a pair is two seats low first, exonerated seats are
    /// parties, a call names its own incident, and nobody protests herself.
    @Test func incidentRecordsAreChecked() throws {
        func report(incident: [UInt8] = [], protest: [UInt8] = []) -> [UInt8] {
            // id 0, report: raceID "", seat 0, roster 1 ("" colour 0), results unrated none, sailing none, one seat's
            // incidents, not closed, no flags.
            [0, 2, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, incident.isEmpty ? 0 : 1] + incident + [0, protest.isEmpty ? 0 : 1] + protest + [0, 0, 0]
        }
        // Incident 5: tick 0, leg 0, seats 1 and 2, contact, nobody exonerated, then its outcome.
        let incident: [UInt8] = [5, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0]
        _ = try Self.decode(.raceSessionReply, report(incident: incident + [1]))
        // Called: the rule call (incident 5, tick 0, port-starboard, 1 on 2, leg 0, one turn, no deadlines).
        let call: [UInt8] = [0, 0, 0, 0, 0, 0, 1, 2, 0, 1, 0]
        _ = try Self.decode(.raceSessionReply, report(incident: incident + [2, 5] + call))
        #expect(throws: WireError.invalidValue("call.incidentId")) { try Self.decode(.raceSessionReply, report(incident: incident + [2, 6] + call)) }
        #expect(throws: WireError.invalidValue("outcome")) { try Self.decode(.raceSessionReply, report(incident: incident + [3])) }
        var swapped = incident
        (swapped[7], swapped[8]) = (2, 1)
        #expect(throws: WireError.invalidValue("parties")) { try Self.decode(.raceSessionReply, report(incident: swapped + [1])) }
        var exonerated = incident
        exonerated[10] = 0b100
        #expect(throws: WireError.invalidValue("exonerated")) { try Self.decode(.raceSessionReply, report(incident: exonerated + [1])) }
        var trigger = incident
        trigger[9] = 2
        #expect(throws: WireError.invalidValue("trigger")) { try Self.decode(.raceSessionReply, report(incident: trigger + [1])) }
        // Protest: tick 0, leg 0, 1 protests 2, no incident.
        _ = try Self.decode(.raceSessionReply, report(protest: [0, 0, 0, 0, 0, 1, 2, 0]))
        #expect(throws: WireError.invalidValue("protested")) { try Self.decode(.raceSessionReply, report(protest: [0, 0, 0, 0, 0, 1, 1, 0])) }
        #expect(throws: WireError.outOfRange("call.incidentId")) {
            try Self.encode(.raceSessionReply(ServiceReply(id: 0, result: .update(.report(WireRaceReport(
                raceID: "", seat: 0, roster: [RosterEntry(name: "", colorIndex: 0)], results: RaceResults(rows: [], rated: false),
                sailing: [], incidents: [WireSeatIncidents(seat: 1, incidents: [Incident(
                    id: 5, tick: 0, leg: 0, parties: SeatPair(1, 2),
                    outcome: .called(RuleCall(incidentId: 6, tick: 0, rule: .portStarboard, offender: 1, victim: 2, leg: 0,
                                              turnsOwed: 1, startDeadlineTick: nil, completeDeadlineTick: nil)))],
                    markTouches: [], protests: [], turnsServed: 0)],
                isClosed: false, flaggedSeats: []))))))
        }
    }

    /// An analytics event's properties go in key order, each key once, and only finite numbers.
    @Test func analyticsPropertiesHaveOneEncoding() throws {
        func batch(_ properties: [WireAnalyticsProperty]) -> Message {
            .analyticsRequest(ServiceRequest(id: 0, call: WireAnalyticsBatch(installID: "i", events: [
                WireAnalyticsEvent(sequence: 1, name: "n", time: 0, properties: properties),
            ])))
        }
        let a = WireAnalyticsProperty(key: "a", value: .bool(true)), b = WireAnalyticsProperty(key: "b", value: .int(-2))
        let sorted = try Self.encode(batch([a, b]))
        #expect(try Self.decode(.analyticsRequest, sorted) == batch([a, b]))
        #expect(throws: WireError.outOfRange("properties")) { try Self.encode(batch([b, a])) }
        #expect(throws: WireError.outOfRange("properties")) { try Self.encode(batch([a, a])) }
        // The same bytes with the two properties swapped.
        let swapped = Array(sorted.prefix(9)) + Array(sorted[13...]) + Array(sorted[9..<13])
        #expect(throws: WireError.invalidValue("properties")) { try Self.decode(.analyticsRequest, swapped) }
        #expect(throws: WireError.outOfRange("double")) { try Self.encode(batch([WireAnalyticsProperty(key: "x", value: .double(.nan))])) }
        var nan = try Self.encode(batch([WireAnalyticsProperty(key: "x", value: .double(1))]))
        nan.replaceSubrange((nan.count - 8)..., with: withUnsafeBytes(of: Double.infinity.bitPattern.littleEndian, Array.init))
        #expect(throws: WireError.invalidValue("double")) { try Self.decode(.analyticsRequest, nan) }
        // UTF-8 byte order, not `String`'s: "Z" (0x5A) before "a" (0x61) before "é" (0xC3 0xA9).
        #expect(WireAnalyticsEvent.keyPrecedes("Z", "a") && WireAnalyticsEvent.keyPrecedes("a", "é"))
        #expect(throws: WireError.outOfRange("deletes")) {
            try Self.encode(.deletionReply(ServiceReply(id: 0, result: .plan(WireDeletionPlan(
                deletes: [.rating, .profile], anonymisesRaceLogs: true, confirmation: "c")))))
        }
    }

    /// A lobby post can be long enough for the server, not the codec, to refuse it as too long.
    @Test func aLongPostReachesTheServer() throws {
        let long = String(repeating: "⛵", count: 1000)
        let post = Message.lobbyRequest(ServiceRequest(id: 1, call: .postText(long)))
        #expect(try Frame(decoding: Frame(seq: 0, tick: 0, message: post).encoded()).message == post)
        #expect(throws: WireError.tooLong("text")) {
            try Self.encode(.lobbyRequest(ServiceRequest(id: 1, call: .postText(String(repeating: "a", count: 8193)))))
        }
    }
}
