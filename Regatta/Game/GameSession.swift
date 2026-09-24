import Foundation
import Observation
import RegattaBots
import RegattaCore
import UIKit

struct RaceMessage: Identifiable {
    enum Tone { case info, good, alert }

    let id = UUID()
    let text: String
    let tone: Tone
    let expires: Date
}

struct ResultRow: Identifiable {
    let id: Int
    let place: String
    let name: String
    let detail: String
    let colorIndex: Int
    let isPlayer: Bool
    /// Marked with the bot glyph (#19).
    let isBot: Bool
}

/// Hosts one race's driver and bridges it to SwiftUI: HUD snapshots, rule-call messages,
/// haptics and results. It never holds a `Race`: a practice race is a `PracticeDriver`.
@Observable
final class GameSession {
    let driver: any RaceDriver
    let scene: GameScene
    /// Names and bot marks, kept outside the simulation (#60).
    let roster: FleetRoster

    var hud = HUDState()
    var messages: [RaceMessage] = []
    var results: [ResultRow] = []
    var isPaused = false
    var playerDone = false

    @ObservationIgnored private var lastCountdownSecond = Int.max
    @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private let notification = UINotificationFeedbackGenerator()

    /// A practice race on the device. `timescale` runs the simulation that many times real time
    /// (`-timescale`, for tests).
    convenience init(config: RaceConfig, timescale: Double = 1) {
        let driver = PracticeDriver(config: config, timescale: timescale)
        self.init(driver: driver, roster: driver.roster)
    }

    init(driver: any RaceDriver, roster: FleetRoster) {
        self.driver = driver
        self.roster = roster
        scene = GameScene(driver: driver, roster: roster)
        scene.session = self
        hud = HUDState(world: driver.renderWorld)
        post("Hold the left or right side of the screen to steer. Be below the line at the gun.", .info, seconds: 6)
    }

    func tackOrGybe() {
        // With `-demo` a bot sails your seat, and the driver refuses the tap.
        guard driver.tap(.tackGybe) else { return }
        impact.impactOccurred(intensity: 0.4)
    }

    /// Pauses a race that can pause; one that can't (online) keeps running.
    func setPaused(_ paused: Bool) {
        isPaused = paused && driver.isPausable
        scene.resetInput()
    }

    func refreshHUD() {
        hud = HUDState(world: driver.renderWorld)
        let now = Date.now
        messages.removeAll { $0.expires < now }
        if playerDone { results = makeResults() }
    }

    func consume(_ events: [RaceEvent]) {
        for event in events { handle(event) }
        let time = driver.currentFrame.time
        if time < 0 {
            let second = Int(ceil(-time))
            if second != lastCountdownSecond {
                lastCountdownSecond = second
                if second <= 5 || second == 10 || second == 30 { impact.impactOccurred(intensity: 0.5) }
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: RaceEvent) {
        let me = driver.myBoatIndex
        func name(_ i: Int) -> String { roster.label(of: i, playerSeat: me) }

        switch event.kind {
        case .gun:
            post("Gun! Race on.", .good)
            impact.impactOccurred(intensity: 1)
        case .ocs(let b) where b == me:
            post("Rule 22 — OCS. You were over at the gun: dip back below the line, then start.", .alert, seconds: 6)
            notification.notificationOccurred(.error)
        case .ocs(let b):
            post("\(name(b)) is OCS", .info)
        case .cleared(let b) where b == me:
            post("Cleared. Now cross the line to start.", .info)
        case .started(let b) where b == me:
            post("You're away.", .good)
        case .foul(let call) where call.offender == me:
            post("Rule \(call.rule.rawValue) — \(call.rule.title). Your foul on \(name(call.victim)): spin a 720°.", .alert, seconds: 6)
            notification.notificationOccurred(.error)
        case .foul(let call) where call.victim == me:
            post("Rule \(call.rule.rawValue) — \(call.rule.title). \(name(call.offender)) fouled you and must spin.", .good, seconds: 5)
            impact.impactOccurred(intensity: 0.8)
        case .foul(let call):
            post("\(name(call.offender)) fouled \(name(call.victim)) — Rule \(call.rule.rawValue)", .info)
        case .markTouch(let b, let mark) where b == me:
            post("Rule 31 — you hit the \(mark). Spin a 360°.", .alert, seconds: 5)
            notification.notificationOccurred(.warning)
        case .penaltyServed(let b) where b == me:
            post("Penalty done.", .good)
            notification.notificationOccurred(.success)
        case .rounded(let b, let mark) where b == me:
            post("Rounded the \(mark) in \(ordinal(placeOfPlayer())).", .good)
            impact.impactOccurred(intensity: 0.6)
        case .finished(let b, let place) where b == me:
            post("Finished \(ordinal(place))!", .good, seconds: 8)
            notification.notificationOccurred(.success)
            finishForPlayer()
        case .disqualified(let b, let reason) where b == me:
            post("DSQ — \(reason).", .alert, seconds: 8)
            notification.notificationOccurred(.error)
            finishForPlayer()
        case .raceOver:
            finishForPlayer()
        default:
            break
        }
    }

    private func finishForPlayer() {
        guard !playerDone else { return }
        playerDone = true
        results = makeResults()
    }

    private func post(_ text: String, _ tone: RaceMessage.Tone, seconds: Double = 4) {
        messages.append(RaceMessage(text: text, tone: tone, expires: .now.addingTimeInterval(seconds)))
        if messages.count > 4 { messages.removeFirst(messages.count - 4) }
    }

    private func placeOfPlayer() -> Int {
        driver.currentFrame.place(of: driver.myBoatIndex)
    }

    private func makeResults() -> [ResultRow] {
        let frame = driver.currentFrame
        let me = driver.myBoatIndex
        return frame.standings.enumerated().map { rank, i in
            let b = frame.boats[i]
            let place: String
            let detail: String
            switch b.status {
            case .finished:
                place = "\(b.place ?? rank + 1)"
                detail = formatClock(b.finishTime ?? 0)
            case .dsq:
                place = "DSQ"
                detail = "Unserved penalty"
            case .dnf:
                place = "DNF"
                detail = "Did not finish"
            case .racing:
                place = "\(rank + 1)"
                detail = "Racing · leg \(b.legIndex + 1)"
            case .prestart, .ocs:
                place = "\(rank + 1)"
                detail = "Not started"
            }
            return ResultRow(id: b.id, place: place, name: roster.name(of: i, playerSeat: me), detail: detail,
                             colorIndex: b.colorIndex, isPlayer: i == me, isBot: roster[i].isBot)
        }
    }
}

func ordinal(_ n: Int) -> String {
    let suffix: String
    switch (n % 10, n % 100) {
    case (_, 11...13): suffix = "th"
    case (1, _): suffix = "st"
    case (2, _): suffix = "nd"
    case (3, _): suffix = "rd"
    default: suffix = "th"
    }
    return "\(n)\(suffix)"
}

func formatClock(_ seconds: Double) -> String {
    // Count down in whole seconds remaining, count up in whole seconds elapsed.
    let total = Int(seconds < 0 ? (-seconds).rounded(.up) : seconds.rounded(.down))
    let sign = seconds < 0 ? "-" : ""
    return String(format: "%@%d:%02d", sign, total / 60, total % 60)
}
