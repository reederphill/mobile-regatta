import Foundation
import Observation
import RegattaCore
import RegattaServices

/// An online race's results as the server streams them (#133, #24): the latest report, filling in live until the
/// close, and the rating change the server pushes for this race. The server decides everything here (ADR 0005).
@MainActor @Observable
final class OnlineResults {
    /// The latest report, nil before the first.
    private(set) var report: RaceReport?
    /// The server cancelled the race: no results, no rating, and it doesn't count. The sheet goes away (Home's notice
    /// is #141's).
    private(set) var isCancelled = false
    /// The race's rating outcome, once pushed.
    private(set) var rating: RatingOutcome?
    /// Online races you had completed before this one: what its earned line counts from.
    let completedBefore: Int
    /// Told once when the race closes with a result of yours that counts as completed (G6): the device's count goes up
    /// by one (`CompletedRacesStore`), so Try it lands on an unlocked design. #163 later sets the server's count.
    @ObservationIgnored var onCompleted: ((RaceID) -> Void)?
    /// Told on every change, so a session rebuilds its sheet even when the race clock has stopped.
    @ObservationIgnored var onChange: (() -> Void)?

    /// `raceID`: the hand-off's race; nil takes the first report's. Changes for any other race are ignored.
    private var raceID: RaceID?
    /// Changes pushed before the report that names the race, by race.
    @ObservationIgnored private var unmatched: [RaceID: RatingOutcome] = [:]
    @ObservationIgnored private var toldCompleted = false
    @ObservationIgnored private let service: any RaceSessionService
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(service: any RaceSessionService, raceID: RaceID? = nil, completedBefore: Int = 0) {
        self.service = service
        self.raceID = raceID
        self.completedBefore = completedBefore
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    /// Starts reading both streams; they run until they end or this goes away.
    func start() {
        guard tasks.isEmpty else { return }
        let service = service
        tasks.append(Task { [weak self] in
            for await update in service.results() { self?.consume(update) }
        })
        tasks.append(Task { [weak self] in
            for await change in service.ratingChanges() { self?.consume(change) }
        })
    }

    /// Reads both streams to their ends: for tests, on a scripted service.
    func run() async {
        for await update in service.results() { consume(update) }
        for await change in service.ratingChanges() { consume(change) }
    }

    func consume(_ update: RaceUpdate) {
        guard !isCancelled else { return }
        switch update {
        case .report(let report):
            if raceID == nil { raceID = report.raceID }
            guard report.raceID == raceID else { return }
            self.report = report
            if rating == nil, let pushed = unmatched.removeValue(forKey: report.raceID) { rating = pushed }
            if report.isClosed, !toldCompleted, let code = report.results.row(of: report.seat)?.code, EarnedUnlock.counts(code) {
                toldCompleted = true
                onCompleted?(report.raceID)
            }
        case .cancelled:
            isCancelled = true
        }
        onChange?()
    }

    func consume(_ change: RatingChange) {
        guard let raceID else {
            unmatched[change.raceID] = change.outcome
            return
        }
        guard change.raceID == raceID else { return }
        rating = change.outcome
        onChange?()
    }

    /// Your rating cell: the pushed change; unrated at once when the closed race wasn't rated (an open report's
    /// `rated` isn't final); pending otherwise.
    var ratingCell: RaceResultViewModel.RatingCell {
        if let rating { return RaceResultViewModel.RatingCell(rating) }
        if let report, report.isClosed, !report.results.rated { return .unrated(.noOtherHumans) }
        return .pending
    }

    /// The earned line for this race in `livery`, once it has closed with a result that counts.
    func earnedLine(livery: Livery) -> RaceResultViewModel.EarnedLine? {
        guard let report, report.isClosed, let code = report.results.row(of: report.seat)?.code else { return nil }
        return EarnedUnlock.line(completedBefore: completedBefore, resultCode: code, livery: livery)
    }

    /// The sheet's model from the latest report, nil before the first or once cancelled.
    func model(entrants: [RaceResultViewModel.Entrant], livery: Livery) -> RaceResultViewModel? {
        guard let report, !isCancelled else { return nil }
        return RaceResultViewModel(report: report, entrants: entrants, rating: ratingCell, earned: earnedLine(livery: livery))
    }
}
