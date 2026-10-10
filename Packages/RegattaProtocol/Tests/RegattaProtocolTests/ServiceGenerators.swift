import RegattaCore
@testable import RegattaProtocol

/// Random service messages (#143), every field drawn from its whole range: each call and result case, and the
/// payloads with something in them (incident lists, rating pushes, lobby history).
extension Gen {
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
    mutating func maybe<T>(_ make: (inout Gen) -> T) -> T? { bool() ? make(&self) : nil }
    mutating func list<T>(_ count: ClosedRange<Int>, _ make: (inout Gen) -> T) -> [T] { (0..<int(count)).map { _ in make(&self) } }
    mutating func anyInt() -> Int { Int(Int64(bitPattern: u64())) >> int(0...63) }
    mutating func anyInt64() -> Int64 { Int64(bitPattern: u64()) >> Int64(int(0...63)) }
    mutating func requestID() -> UInt32 { bool() ? u32() : UInt32(int(0...300)) }
    mutating func seat() -> Int { int(0...255) }

    mutating func player() -> WirePlayer {
        WirePlayer(gamePlayerID: string(), alias: string(), isUnderage: bool(), isPersonalizedCommunicationRestricted: bool(),
                   isMultiplayerGamingRestricted: bool())
    }

    mutating func identitySignature() -> WireIdentitySignature {
        WireIdentitySignature(gamePlayerID: string(), teamPlayerID: string(), publicKeyURL: string(), signature: bytes(0...64),
                              salt: bytes(0...16), timestamp: u64())
    }

    mutating func rating() -> WireRating { WireRating(value: anyInt(), isProvisional: bool()) }

    mutating func refusal() -> WireQueueRefusal {
        switch int(0...6) {
        case 0: .notSignedIn
        case 1: .termsNotAccepted
        case 2: .multiplayerRestricted
        case 3: .cooldown(secondsRemaining: anyInt())
        case 4: .suspended(until: maybe { $0.anyInt64() })
        case 5: .attestationFailed
        default: .updateRequired
        }
    }

    mutating func queueState() -> WireQueueState {
        switch int(0...3) {
        case 0: .idle
        case 1: .unavailable(refusal())
        case 2: .queued(queuedPlayers: anyInt(), secondsToLock: anyInt())
        default: .fleetLocked
        }
    }

    mutating func livery() -> Livery {
        Livery(design: DesignID(string()), colours: list(0...4) { SwatchID($0.string(1...12)) }, sailNumber: anyInt())
    }

    /// The fleet-lock briefing (#147): the fleet's bot flags are the setup's seat kinds.
    mutating func briefing() -> WireBriefing {
        let setup = setup()
        return WireBriefing(
            setup: setup, tide: payload(),
            fleet: setup.seats.map { kind in
                WireBriefingSeat(name: string(), isBot: kind == .bot, livery: livery(), rating: kind == .bot ? nil : maybe { $0.anyInt() })
            },
            yourSeat: int(0...(setup.fleetSize - 1)), briefingSeconds: int(0...3600), gunInSeconds: int(0...3600))
    }

    mutating func ruleCall(incidentId: Int) -> RuleCall {
        let deadlines = bool() ? (tick(), tick()) : nil
        return RuleCall(incidentId: incidentId, tick: tick(), rule: pick(RacingRule.allCases), offender: seat(), victim: seat(),
                        leg: seat(), turnsOwed: seat(), startDeadlineTick: deadlines?.0, completeDeadlineTick: deadlines?.1)
    }

    mutating func incident() -> Incident {
        let id = int(0...65_535), low = int(0...254)
        let parties = SeatPair(low, int((low + 1)...255))
        let exonerated = [parties.low, parties.high].filter { _ in bool() }
        let outcome: Incident.Outcome = switch int(0...2) {
        case 0: .pending
        case 1: .noCall
        default: .called(ruleCall(incidentId: id))
        }
        return Incident(id: id, tick: tick(), leg: seat(), parties: parties, trigger: bool() ? .contact : .nearMiss,
                        exonerated: exonerated, outcome: outcome)
    }

    mutating func protest() -> Protest {
        let protester = seat()
        var protested = seat()
        if protested == protester { protested = (protester + 1) % 256 }
        return Protest(tick: tick(), leg: seat(), protester: protester, protested: protested, matchedIncidentId: maybe { $0.int(0...65_535) })
    }

    mutating func raceReport() -> WireRaceReport {
        let n = int(1...16)
        return WireRaceReport(
            raceID: string(), seat: int(0...(n - 1)),
            roster: (0..<n).map { _ in RosterEntry(name: string(), colorIndex: int(0...255)) },
            results: results(), sailing: list(0...n) { $0.int(0...(n - 1)) },
            incidents: list(0...3) { g in
                WireSeatIncidents(seat: g.seat(), incidents: g.list(0...4) { $0.incident() },
                                  markTouches: g.list(0...3) { MarkTouch(tick: $0.tick(), leg: $0.seat(), seat: $0.seat(), mark: $0.string()) },
                                  protests: g.list(0...3) { $0.protest() }, turnsServed: g.anyInt())
            },
            isClosed: bool(), flaggedSeats: list(0...n) { $0.int(0...(n - 1)) })
    }

    mutating func ratingChange() -> WireRatingChange {
        WireRatingChange(raceID: string(), outcome: bool() ? .rated(before: rating(), after: rating()) : .unrated)
    }

    mutating func author() -> WireLobbyAuthor {
        WireLobbyAuthor(gamePlayerID: string(), nickname: string(), rating: rating(), deck: string(), sail: string())
    }

    mutating func lobbyMessage() -> WireLobbyMessage {
        let kind: WireLobbyMessage.Kind = switch int(0...3) {
        case 0: .post(author: author(), body: .text(string(0...300)), isSent: bool())
        case 1: .post(author: author(), body: .quickChat(pick(WireQuickChat.allCases)), isSent: bool())
        case 2: .gun(venue: string(), boats: anyInt(), humans: anyInt())
        default: .winner(venue: string(), nickname: string())
        }
        return WireLobbyMessage(id: string(), kind: kind)
    }

    mutating func lobbyState() -> WireLobbyState {
        let standing: WireChatStanding = switch int(0...2) {
        case 0: .clear
        case 1: .muted(until: anyInt64(), isAutomatic: bool())
        default: .banned
        }
        return WireLobbyState(closure: maybe { $0.pick(WireLobbyClosure.allCases) }, canPostFreeText: bool(), standing: standing)
    }

    mutating func lobbyError() -> WireLobbyError {
        switch int(0...9) {
        case 0: .closed(pick(WireLobbyClosure.allCases))
        case 1: .freeTextLocked
        case 2: .empty
        case 3: .tooLong(limit: anyInt())
        case 4: .rateLimited(retryAfterSeconds: anyInt())
        case 5: .muted(until: anyInt64())
        case 6: .banned
        case 7: .unknownMessage
        case 8: .notReportable
        default: .cannotBlockSelf
        }
    }

    mutating func profile() -> WireProfile {
        let suspension: WireProfile.Suspension? = switch int(0...2) {
        case 0: nil
        case 1: .permanent
        default: .until(anyInt64())
        }
        return WireProfile(gamePlayerID: string(), nickname: string(), rating: rating(), completedRaces: anyInt(), wins: anyInt(),
                           suspension: suspension, earned: list(0...4) { $0.string() },
                           next: maybe { WireMilestone(design: $0.string(), completedRaces: $0.anyInt()) }, livery: livery())
    }

    mutating func analyticsBatch() -> WireAnalyticsBatch {
        WireAnalyticsBatch(installID: string(), events: list(0...5) { g in
            var keys: [String] = []
            for _ in 0..<g.int(0...5) {
                let key = g.string(1...8)
                if !keys.contains(key) { keys.append(key) }
            }
            keys.sort(by: WireAnalyticsEvent.keyPrecedes)
            return WireAnalyticsEvent(sequence: g.anyInt(), name: g.string(), time: g.anyInt64(), properties: keys.map { key in
                let value: WireAnalyticsValue = switch g.int(0...3) {
                case 0: .int(g.anyInt64())
                case 1: .double(g.double(-1e12, 1e12))
                case 2: .string(g.string())
                default: .bool(g.bool())
                }
                return WireAnalyticsProperty(key: key, value: value)
            })
        })
    }

    mutating func deletionPlan() -> WireDeletionPlan {
        WireDeletionPlan(deletes: WireOnlineData.allCases.filter { _ in bool() }, anonymisesRaceLogs: bool(), confirmation: string())
    }

    /// A random service message of `type`.
    mutating func serviceMessage(_ type: MessageType) -> Message {
        let id = requestID()
        switch type {
        case .identityRequest: return .identityRequest(ServiceRequest(id: id, call: pick(IdentityCall.allCases)))
        case .termsRequest: return .termsRequest(ServiceRequest(id: id, call: bool() ? .status : .accept(version: anyInt())))
        case .queueRequest: return .queueRequest(ServiceRequest(id: id, call: pick(QueueCall.allCases)))
        case .raceSessionRequest: return .raceSessionRequest(ServiceRequest(id: id, call: pick(RaceSessionCall.allCases)))
        case .lobbyRequest:
            let call: LobbyCall = switch int(0...10) {
            case 0: .state
            case 1: .history
            case 2: .openFeed
            case 3: .postText(string(0...300))
            case 4: .postQuickChat(pick(WireQuickChat.allCases))
            case 5: .block(gamePlayerID: string())
            case 6: .unblock(gamePlayerID: string())
            case 7: .blockedPlayers
            case 8: .reportMessage(messageID: string())
            case 9: .reportPlayer(gamePlayerID: string())
            default: .reportRace(raceID: string(), seat: seat(), reason: pick(WireRaceReportReason.allCases))
            }
            return .lobbyRequest(ServiceRequest(id: id, call: call))
        case .profileRequest: return .profileRequest(ServiceRequest(id: id, call: bool() ? .profile : .saveLivery(livery())))
        case .analyticsRequest: return .analyticsRequest(ServiceRequest(id: id, call: analyticsBatch()))
        case .deletionRequest: return .deletionRequest(ServiceRequest(id: id, call: bool() ? .plan : .delete(confirmation: string())))
        case .streamNext: return .streamNext(StreamNext(id: id, stream: requestID()))
        case .streamClose: return .streamClose(StreamClose(stream: id))
        case .identityReply:
            let result: IdentityResult = switch int(0...3) {
            case 0: .state(maybe { $0.player() })
            case 1: .gamePlayerID(maybe { $0.string() })
            case 2: .signature(identitySignature())
            default: .notSignedIn
            }
            return .identityReply(ServiceReply(id: id, result: result))
        case .termsReply:
            let status: WireTermsStatus = bool() ? .accepted(version: anyInt())
                : .needsAcceptance(current: anyInt(), lastAccepted: maybe { $0.anyInt() })
            return .termsReply(ServiceReply(id: id, result: bool() ? .status(status) : .staleVersion(current: anyInt())))
        case .queueReply:
            let result: QueueResult = switch int(0...4) {
            case 0: .state(queueState())
            case 1: .done
            case 2: .refused(refusal())
            case 3: .alreadyQueued
            default: .notQueued
            }
            return .queueReply(ServiceReply(id: id, result: result))
        case .raceSessionReply:
            let handOff = WireHandOff(raceID: string(), token: bytes(0...64), briefing: maybe { $0.briefing() })
            let result: RaceSessionResult = switch int(0...7) {
            case 0: .handOff(handOff)
            case 1: .rejoin(WireRejoinOffer(handOff: handOff, seat: seat(), tick: tick(), expectedCloseTick: maybe { $0.tick() }))
            case 2: .update(.report(raceReport()))
            case 3: .update(.cancelled(RaceCancelled.Reason(code: UInt8(int(0...255)))))
            case 4: .ratingChange(ratingChange())
            case 5: .lastRace(report: raceReport(), rating: maybe { $0.ratingChange() })
            case 6: .noLastRace
            default: .noRace
            }
            return .raceSessionReply(ServiceReply(id: id, result: result))
        case .lobbyReply:
            let result: LobbyResult = switch int(0...8) {
            case 0: .state(lobbyState())
            case 1: .history(list(0...6) { $0.lobbyMessage() })
            case 2: .event(.state(lobbyState()))
            case 3: .event(.message(lobbyMessage()))
            case 4: .event(.removed(messageID: string()))
            case 5: .posted(lobbyMessage())
            case 6: .done
            case 7: .blockedPlayers(list(0...4) { WireBlockedPlayer(gamePlayerID: $0.string(), nickname: $0.string()) })
            default: .failure(lobbyError())
            }
            return .lobbyReply(ServiceReply(id: id, result: result))
        case .profileReply:
            let result: ProfileResult = switch int(0...4) {
            case 0: .profile(profile())
            case 1: .livery(livery())
            case 2: .notSignedIn
            case 3: .invalidLivery(pick(WireLiveryProblem.allCases))
            default: .liveryLocked
            }
            return .profileReply(ServiceReply(id: id, result: result))
        case .analyticsReply:
            let result: AnalyticsResult = switch int(0...2) {
            case 0: .receipt(accepted: anyInt(), duplicates: anyInt())
            case 1: .batchTooLarge(max: anyInt())
            default: .unavailable
            }
            return .analyticsReply(ServiceReply(id: id, result: result))
        case .deletionReply:
            let result: DeletionResult = switch int(0...4) {
            case 0: .plan(deletionPlan())
            case 1: .deleted
            case 2: .notSignedIn
            case 3: .nothingToDelete
            default: .invalidConfirmation
            }
            return .deletionReply(ServiceReply(id: id, result: result))
        case .streamEnd: return .streamEnd(StreamEnd(id: id))
        case .sessionRequest:
            let call: SessionCall = switch int(0...2) {
            case 0: .signIn(signature: identitySignature(), player: player())
            case 1: .resume(token: bytes(0...64), player: player())
            default: .signOut
            }
            return .sessionRequest(ServiceRequest(id: id, call: call))
        case .sessionReply:
            let result: SessionResult = switch int(0...2) {
            case 0: .signedIn(token: bytes(0...64), player: player())
            case 1: .refused(pick(WireSessionRefusal.allCases))
            default: .signedOut
            }
            return .sessionReply(ServiceReply(id: id, result: result))
        default: fatalError("\(type) isn't a service message")
        }
    }
}
