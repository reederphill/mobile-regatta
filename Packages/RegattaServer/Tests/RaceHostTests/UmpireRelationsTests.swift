import RaceHost
import RegattaCore
import RegattaProtocol
import Testing

/// The host as the online rules authority (#96, ADR 0005): each seat's snapshot carries the umpire's relations of
/// her boat, targeted notices reach only their recipients, and a seat's event ids run on across a rejoin.
struct UmpireRelationsTests {
    /// Acceptance (#96): every seat's snapshot carries the server umpire's relations of her boat to each boat in
    /// range (`keepClearRelations`, the glow's source, and the rule 17 restrictions), the authoritative race's at
    /// the snapshot's tick, which a replay of the host's log rebuilds; and a 16-boat snapshot is still at most 512 B.
    @Test func snapshotRelationBitsAreTheServerUmpiresForEveryPairInRange() async throws {
        let rig = try await Rig(humans: 16, seats: 16)
        var transports = [rig.seat0]
        for seat in 1..<16 {
            let transport = RecordingTransport()
            #expect(await rig.host.attach(seat: seat, transport: transport))
            transports.append(transport)
        }
        var present = 0
        for tick in stride(from: -240, through: -30, by: 30) {
            await rig.run(to: tick)
            let race = try Replayer.replay(await rig.host.log)
            #expect(race.tick == tick)
            for (seat, transport) in transports.enumerated() {
                guard let frame = transport.frames.last(where: { if case .snapshot = $0.message { true } else { false } }),
                      case .snapshot(let snapshot) = frame.message, let relations = snapshot.relations else {
                    Issue.record("seat \(seat): no snapshot with relations")
                    continue
                }
                #expect(frame.tick == tick)
                #expect(relations == WireRelation.relations(of: seat, in: race))
                let decoded = WireRelation.umpireRelations(relations, seat: seat)
                let server = race.keepClearRelations(of: seat)
                for other in race.boats.indices where relations[other].keepClear != nil {
                    #expect(decoded.keepClear[other] == server[other])
                    present += 1
                }
                let bytes = transport.sentBytes.last { (try? Frame(decoding: $0))?.tick == tick && $0.first == frame.message.type.rawValue }
                #expect((bytes?.count ?? .max) <= 512)
            }
        }
        #expect(present > 0, "the start line has boats in range with right of way")
    }

    /// Acceptance (#96): a mark-room notice reaches only its two boats' clients, with its audience
    /// (`EventAudience(_:)`), as the host sends every race event.
    @Test func markRoomNoticeReachesOnlyItsRecipientsClients() async throws {
        let rig = try await Rig(humans: 4)
        let others = (1..<4).map { _ in RecordingTransport() }
        for (k, transport) in others.enumerated() { #expect(await rig.host.attach(seat: k + 1, transport: transport)) }
        await rig.run(to: -250)
        let notice = RaceEvent.Kind.markRoomNotice(boat: 1, entitledOver: 3, mark: "Windward")
        await rig.host.sendEvent(notice, to: EventAudience(notice))
        #expect(others[0].events.map(\.kind) == [notice])
        #expect(others[2].events.map(\.kind) == [notice])
        #expect(others[1].events.isEmpty)
        #expect(rig.seat0.events.isEmpty)
    }

    /// Every event's id (its reliable seq, `Frame.raceEvent`) is unique for the seat for the whole race: a rejoin
    /// carries the numbering on, and its resync restarts the client's stream there.
    @Test func eventIdsRunOnAcrossARejoin() async throws {
        let rig = try await Rig()
        await rig.run(to: -250)
        await rig.host.sendEvent(.gun, to: .everyone)
        await rig.host.sendEvent(.started(seat: 0), to: .everyone)
        let before = rig.seat0.events.compactMap(\.id)
        #expect(before.count == 2)
        await rig.host.disconnect(seat: 0)
        let back = RecordingTransport()
        #expect(await rig.host.attach(seat: 0, transport: back))
        let resync = back.frames.compactMap { if case .resync(let resync) = $0.message { resync } else { nil } }.first
        #expect(resync?.eventState.nextEventSeq == (before.max() ?? 0) + 1)
        await rig.host.sendEvent(.gun, to: .everyone)
        let after = back.events.compactMap(\.id)
        #expect(after == [(before.max() ?? 0) + 1])
    }
}
