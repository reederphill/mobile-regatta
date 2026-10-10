// `regatta-botsuite tack-sweep` (#465): the #456 hand-steered tack and gybe sweep. Probe branch only.
import BotSuite
import Foundation
import RegattaCore

enum TackSweep {
    static let outDir = URL(fileURLWithPath: ".build/tack-sweep", isDirectory: true)
    static let resultsDir = URL(fileURLWithPath: "results", isDirectory: true)
    static let hull = 4.9
    static let dt = Race.dt

    static func main(arguments: [String]) -> Int32 {
        do {
            let options = try Options(arguments)
            if options.help {
                print(Options.usage)
                return 0
            }
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
            let book = try WindBook.load()
            if let name = options.caseName {
                try runCase(name, options: options, book: book)
                return 0
            }
            if options.report {
                try writeReport(book: book)
                return 0
            }
            switch options.stage {
            case 0: try stage0(options, book: book)
            case 1: try stage1(options, book: book)
            case 2: try stage2(options, book: book)
            case 3: try stage3(options, book: book)
            case 4: try stage4(options, book: book)
            case 5: try stage5(options, book: book)
            default:
                fputs("tack-sweep: --stage must be 0...4\n\(Options.usage)\n", stderr)
                return 2
            }
            return 0
        } catch {
            fputs("tack-sweep: \(error)\n", stderr)
            return 2
        }
    }

    // MARK: - Stage 0

    static func stage0(_ options: Options, book: WindBook) throws {
        let jobs = options.jobs
        let boat = try boatClass(.stock)
        let bench = benchmark(boat)
        print("Machine / cores / --jobs: \(jobs) jobs on \(ProcessInfo.processInfo.activeProcessorCount) active processors")
        let head = try shell("git rev-parse HEAD")
        print("Probe branch + head SHA: probe/456-tack-sweep \(head)")
        print(String(format: "Stage 0: dynamics %.0f ns/tick (bench %d ticks)", bench.ns, bench.ticks))

        let cell = Cell(knots: 10, entry: 1, seed: nil)
        func losses(_ helm: Helm, _ maneuver: Maneuver, _ params: SweepParams) throws -> (tack: Double, gybe: Double) {
            let tack = try run(helm, .tack, cell, params: params, boat: boat, book: book).loss25
            let gybe = try run(helm, .gybe, cell, params: params, boat: try boatClass(params), book: book).loss30
            return (tack, gybe)
        }
        let stock = SweepParams.stock
        var lines: [String] = []
        for helm in [Helm.slam, .rudder75, .rudder50, .rudder25] {
            let pair = try losses(helm, .tack, stock)
            let text = String(format: "%@ tack %.3f / gybe %.3f", helm.rawValue, pair.tack, pair.gybe)
            print("  \(text)")
            lines.append(text)
        }
        let targets = ["slam": (1.09, 1.10), "rudder75": (1.34, 1.19), "rudder50": (1.79, 1.37), "rudder25": (3.78, 1.93)]
        var baselineOK = true
        for (name, want) in targets {
            let helm = Helm(rawValue: name)!
            let got = try losses(helm, .tack, stock)
            if abs(got.tack - want.0) > 0.1 || abs(got.gybe - want.1) > 0.1 { baselineOK = false }
        }
        if baselineOK {
            print("Baseline within 0.1 L of #454.")
        } else {
            print("BASELINE MISS: 25% rudder is outside 0.1 L. Owner 2026-10-09 accepted it; continuing.")
        }

        func gap(_ params: SweepParams) throws -> Double {
            let scored = try score(params, book: book, mode: .tackGap, jobs: 1)
            return scored.bestTack - scored.slamTack
        }
        print(String(format: "best-minus-slam (10 kn, 100%%, all wind cases), mechanics off: %.3f", try gap(stock)))
        for name in ["M1", "M2", "M3", "M4"] {
            print(String(format: "  %@ at range limit: %.3f", name, try gap(SweepParams.limit(name))))
        }
        let sized = Date()
        _ = try score(stock, book: book, mode: .tack, jobs: 1)
        let one = Date().timeIntervalSince(sized)
        let stage1Min = one * 4096 / Double(max(jobs, 1)) / 60
        let stage2Min = one * 2.5 * 9700 / Double(max(jobs, 1)) / 60
        print(String(format: "Release size: 1 tack candidate %.2f s on 1 job. Stage 1 ~ %.0f min, stage 2 ~ %.0f min at %d jobs.",
                     one, stage1Min, stage2Min, jobs))
        _ = lines
    }

    // MARK: - Stages 1 to 3

    static func stage1(_ options: Options, book: WindBook) throws {
        let axes: [(WritableKeyPath<SweepParams, Double>, [Double])] = [
            (\.rudderDrag, levels(0.10, 0.60, 4)),
            (\.topTurnRate, levels(24, 48, 4)),
            (\.minTurnRate, levels(4, 16, 4)),
            (\.fullSteerKnots, levels(1.5, 7, 4)),
            (\.speedingUp, levels(1.5, 4.5, 4)),
            (\.noGo, levels(2.5, 8, 4)),
        ]
        var grid: [SweepParams] = []
        enumerate(axes.map(\.1)) { values in
            var p = SweepParams.stock
            for (i, axis) in axes.enumerated() { p[keyPath: axis.0] = values[i] }
            grid.append(p)
        }
        print("Stage 1 file grid: \(grid.count) candidates, \(options.jobs) jobs")
        let fileRows = try rank(grid, book: book, mode: .tack, jobs: options.jobs, csv: "grid1.csv")
        let mechAxes: [(WritableKeyPath<SweepParams, Double>, [Double])] = [
            (\.dragExponent, [1, 2, 3]),
            (\.dragTurnRateTerm, [0, 0.5, 1]),
            (\.windBandRateFactor, [1, 0.7, 0.4]),
        ]
        var mechGrid: [SweepParams] = []
        for base in fileRows.prefix(5) {
            enumerate(mechAxes.map(\.1)) { values in
                var p = base.params
                for (i, axis) in mechAxes.enumerated() { p[keyPath: axis.0] = values[i] }
                p.windBandDegrees = p.windBandRateFactor == 1 ? 0 : 20
                mechGrid.append(p)
            }
        }
        print("Stage 1 mechanic grid on top 5: \(mechGrid.count)")
        let mechRows = try rank(mechGrid, book: book, mode: .tack, jobs: options.jobs, csv: "grid1-mechanics.csv")
        let best = (fileRows + mechRows).sorted { $0.score < $1.score }
        try save(Array(best.prefix(5)), name: "stage1-top.json")
        print("Stage 1 best 3 scores: \(best.prefix(3).map { String(format: "%.3f", $0.score) }.joined(separator: ", "))")
    }

    static func stage2(_ options: Options, book: WindBook) throws {
        let top = try loadRows("stage1-top.json")
        let keep = top.prefix(options.cut ?? 5)
        let axes: [(WritableKeyPath<SweepParams, Double>, [Double])] = [
            (\.onSpeed, levels(6, 10, 3)),
            (\.offSpeed, levels(4, 8, 3)),
            (\.onMaxAWA, levels(80, 105, 3)),
            (\.slowingDown, levels(4, 14, 3)),
            (\.byTheLeeLoss, levels(0.01, 0.05, 3)),
            (\.collapse, levels(6, 16, 3)),
            (\.byTheLeeLimit, levels(12, 30, 3)),
        ]
        var grid: [SweepParams] = []
        for base in keep {
            enumerate(axes.map(\.1)) { values in
                var p = base.params
                for (i, axis) in axes.enumerated() { p[keyPath: axis.0] = values[i] }
                guard p.valid else { return }
                grid.append(p)
            }
        }
        print("Stage 2: \(grid.count) candidates on \(keep.count) stage-1 sets")
        let rows = try rank(grid, book: book, mode: .full, jobs: options.jobs, csv: "grid2.csv")
        guard var best = rows.first else { throw SweepError.empty }
        for fall in [1.0, 6.0] {
            for slew in [2.0, 10.0] {
                var p = best.params
                p.fallOff = fall
                p.rudderSlew = slew
                let card = try score(p, book: book, mode: .full, jobs: options.jobs)
                print(String(format: "  fallOff %.0f slew %.0f score %.3f", fall, slew, card.score))
                if card.score < best.score { best = Row(params: p, score: card.score, card: card) }
            }
        }
        try save([best] + rows.dropFirst().prefix(4), name: "stage2-top.json")
        print(String(format: "Stage 2 best score: %.3f", best.score))
    }

    static func stage3(_ options: Options, book: WindBook) throws {
        let top = try loadRows("stage2-top.json")
        guard let start = top.first else { throw SweepError.empty }
        print(String(format: "Refine from %.3f", start.score))
        let seeds = jointMechanicSeeds(start.params)
        print("Joint M1+M2+M3 seeds: \(seeds.count) (M2 with M1, M2 with M3, all three)")
        let seeded = try rank(seeds, book: book, mode: .full, jobs: options.jobs, csv: "joint-seeds.csv")
        guard let bestSeed = seeded.first else { throw SweepError.empty }
        print(String(format: "Best joint seed %.3f (stage 2 %.3f) p %.2f k %.2f c %.2f band %.0f factor %.2f settle %.0f bonus %.2f lag %.1f",
                     bestSeed.score, start.score, bestSeed.params.dragExponent, bestSeed.params.dragTurnRateTerm,
                     bestSeed.params.overshootCost, bestSeed.params.windBandDegrees, bestSeed.params.windBandRateFactor,
                     bestSeed.params.settleDegrees, bestSeed.params.settleBonus, bestSeed.params.driveLagSeconds))
        let refined = try refine(bestSeed.params, knobs: SweepParams.knobs, book: book, jobs: options.jobs)
        try save([refined], name: "refine-best.json")
        print(String(format: "Refine score: %.3f", refined.score))
        var subsetRows: [Row] = []
        for mask in 0..<16 {
            var forced = refined.params
            forced.forceOff(mask)
            let knobs = SweepParams.knobs.filter { !$0.forcedOff(mask) }
            let row = try refine(forced, knobs: knobs, book: book, jobs: options.jobs)
            subsetRows.append(row)
            print(String(format: "  subset %02d score %.3f", mask, row.score))
        }
        try save(subsetRows, name: "subsets.json")
    }

    static func stage4(_ options: Options, book: WindBook) throws {
        let rows = try loadRows(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("refine-best.json").path)
            ? "refine-best.json" : "stage2-top.json")
        let top = Array(rows.prefix(5))
        print("Stage 4 race-level confirm, \(top.count) sets, gusty seeds")
        for (index, row) in top.enumerated() {
            let dyn = try score(row.params, book: book, mode: .gustyOnly, jobs: options.jobs)
            let race = try raceScore(row.params, jobs: options.jobs)
            print(String(format: "  #%d dynamics best/slam tack %.3f/%.3f  race %.3f/%.3f",
                         index + 1, dyn.bestTack, dyn.slamTack, race.bestTack, race.slamTack))
        }
    }

    // MARK: - Ranking

    struct Row: Codable, Sendable {
        var params: SweepParams
        var score: Double
        var card: Scorecard
    }

    static func jointMechanicSeeds(_ base: SweepParams) -> [SweepParams] {
        // Keep the stage-2 file values (including dragExponent). Overlay M2 with M1 and with M3
        // so the refine starts from a combination, not from M2 alone and not from mechanics wiped.
        func overlay(p: Double? = nil, k: Double? = nil, c: Double? = nil, band: Double? = nil,
                     factor: Double? = nil, settle: Double? = nil, bonus: Double? = nil, lag: Double? = nil) -> SweepParams {
            var next = base
            if let p { next.dragExponent = p }
            if let k { next.dragTurnRateTerm = k }
            if let c { next.overshootCost = c }
            if let band { next.windBandDegrees = band }
            if let factor { next.windBandRateFactor = factor }
            if let settle { next.settleDegrees = settle }
            if let bonus { next.settleBonus = bonus }
            if let lag { next.driveLagSeconds = lag }
            return next
        }
        return [
            base,
            overlay(band: 40, factor: 0.4),
            overlay(k: 0.5, c: 0.5, band: 20, factor: 0.7),
            overlay(p: 3, k: 1, c: 1, band: 40, factor: 0.4),
            overlay(band: 40, factor: 0.4, settle: 8, bonus: 0.5, lag: 1.5),
            overlay(k: 0.5, c: 0.5, band: 20, factor: 0.7, settle: 8, bonus: 0.5, lag: 1.5),
            overlay(p: 3, k: 1, c: 1, band: 40, factor: 0.4, settle: 15, bonus: 1, lag: 3),
        ]
    }

    static func rank(_ grid: [SweepParams], book: WindBook, mode: Mode, jobs: Int, csv: String) throws -> [Row] {
        var rows: [Row] = []
        let checkpointURL = outDir.appendingPathComponent(csv + ".partial.json")
        if let data = try? Data(contentsOf: checkpointURL),
           let prior = try? JSONDecoder().decode([Row].self, from: data),
           prior.count <= grid.count,
           prior.isEmpty || prior[0].params == grid[0] {
            rows = prior
        }
        var done = rows.count
        if done >= grid.count {
            print("  \(csv) already complete (\(rows.count))")
            return rows.sorted { $0.score < $1.score }
        }
        let batch = max(jobs, 1) * 4
        let started = Date()
        let resumed = done
        let url = outDir.appendingPathComponent(csv)
        if done == 0 {
            try ("score," + SweepParams.header + "," + Scorecard.header + "\n").write(to: url, atomically: true, encoding: .utf8)
        } else {
            print("  resuming \(csv) at \(done)/\(grid.count)")
        }
        while done < grid.count {
            let end = min(done + batch, grid.count)
            let slice = Array(grid[done..<end])
            let cards = try inParallel(slice, jobs: jobs) { params -> Scorecard in
                try score(params, book: book, mode: mode, jobs: 1)
            }
            var text = ""
            for (params, card) in zip(slice, cards) {
                let row = Row(params: params, score: card.score, card: card)
                rows.append(row)
                text += "\(card.score)," + params.csv + "," + card.csv + "\n"
            }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try handle.close()
            }
            done = end
            try JSONEncoder().encode(rows).write(to: checkpointURL, options: .atomic)
            let fresh = Double(done - resumed)
            let left = Date().timeIntervalSince(started) / fresh * Double(grid.count - done)
            print(String(format: "  %d/%d  %.0f s left  best %.3f", done, grid.count, left, rows.map(\.score).min() ?? .nan))
            fflush(stdout)
        }
        return rows.sorted { $0.score < $1.score }
    }

    static func refine(_ start: SweepParams, knobs: [Knob], book: WindBook, jobs: Int) throws -> Row {
        var best = start
        var bestCard = try score(best, book: book, mode: .full, jobs: 1)
        var steps = knobs.map(\.step)
        var halvings = 0
        var rounds = 0
        while halvings < 3 {
            rounds += 1
            var trials: [SweepParams] = []
            for (i, knob) in knobs.enumerated() {
                for direction in [-1.0, 1.0] {
                    var trial = best
                    let next = (trial[keyPath: knob.path] + direction * steps[i]).clamped(to: knob.lo...knob.hi)
                    guard next != trial[keyPath: knob.path] else { continue }
                    trial[keyPath: knob.path] = next
                    guard trial.valid else { continue }
                    trials.append(trial)
                }
            }
            let cards = try inParallel(trials, jobs: jobs) { try score($0, book: book, mode: .full, jobs: 1) }
            var improved = false
            for (trial, card) in zip(trials, cards) where card.score < bestCard.score - 1e-6 {
                best = trial
                bestCard = card
                improved = true
            }
            if improved {
                print(String(format: "  refine round %d -> %.3f", rounds, bestCard.score))
            } else {
                halvings += 1
                steps = steps.map { $0 / 2 }
            }
        }
        return Row(params: best, score: bestCard.score, card: bestCard)
    }

    // MARK: - Scoring

    enum Mode { case tack, tackGap, full, gustyOnly }

    static func score(_ params: SweepParams, book: WindBook, mode: Mode, jobs: Int) throws -> Scorecard {
        let boat = try boatClass(params)
        let cells = cells(mode)
        let tackHelms = Helm.tack
        let gybeHelms = mode == .tack || mode == .tackGap ? [] : Helm.gybe
        let deepHelms = mode == .full || mode == .gustyOnly ? Helm.deep : []
        struct Job: Sendable { var helm: Helm; var maneuver: Maneuver; var cell: Cell }
        var jobsList: [Job] = []
        for cell in cells {
            for helm in tackHelms { jobsList.append(Job(helm: helm, maneuver: .tack, cell: cell)) }
            for helm in gybeHelms { jobsList.append(Job(helm: helm, maneuver: .gybe, cell: cell)) }
            for helm in deepHelms { jobsList.append(Job(helm: helm, maneuver: .run, cell: cell)) }
        }
        let metrics = try inParallel(jobsList, jobs: jobs) { job in
            try run(job.helm, job.maneuver, job.cell, params: params, boat: boat, book: book)
        }
        var by: [String: RunMetrics] = [:]
        for (job, metric) in zip(jobsList, metrics) {
            by["\(job.helm.rawValue)|\(job.maneuver.rawValue)|\(job.cell.key)"] = metric
        }
        func pick(_ helm: Helm, _ maneuver: Maneuver, _ cell: Cell) -> RunMetrics? {
            by["\(helm.rawValue)|\(maneuver.rawValue)|\(cell.key)"]
        }
        func meanLoss(_ helms: [Helm], _ maneuver: Maneuver, _ wanted: [Cell], _ loss: (RunMetrics) -> Double) -> Double {
            let values = wanted.flatMap { cell in helms.compactMap { pick($0, maneuver, cell) }.map(loss) }
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }
        let tackCells = cells.filter { $0.knots == 10 && $0.entry == 1 }
        let bestTack = tackCells.map { cell -> Double in
            Helm.tack.filter(\.countsForBest).compactMap { pick($0, .tack, cell)?.loss25 }.min() ?? 0
        }.mean
        let slamTack = meanLoss([.slam], .tack, tackCells) { $0.loss25 }
        let gentle = tackCells.map { cell -> Double in
            let best = Helm.tack.filter(\.countsForBest).compactMap { pick($0, .tack, cell)?.loss25 }.min() ?? 0
            let a = pick(.rudder50, .tack, cell)?.loss25 ?? best
            let b = pick(.smooth20, .tack, cell)?.loss25 ?? best
            return max(a - best, b - best)
        }.mean
        let lightCells = cells.filter { $0.knots == 6 && $0.entry == 0.7 }
        let light = lightCells.map { cell -> Double in
            let slam = pick(.slam, .tack, cell)?.loss20 ?? 0
            let bear = Helm.bear.compactMap { pick($0, .tack, cell)?.loss20 }.min() ?? slam
            return slam - bear
        }.mean
        let strongCells = cells.filter { $0.knots == 14 && $0.entry == 0.7 }
        let strong = strongCells.map { cell -> Double in
            let slam = pick(.slam, .tack, cell)?.loss20 ?? 0
            let bear = Helm.bear.compactMap { pick($0, .tack, cell)?.loss20 }.min() ?? slam
            return bear - slam
        }.mean
        let gybeCells = cells.filter { ($0.knots == 10 || $0.knots == 14) && $0.entry == 1 }
        let bestGybe = gybeCells.map { cell -> Double in
            Helm.gybe.filter(\.countsForBest).compactMap { pick($0, .gybe, cell)?.loss30 }.min() ?? 0
        }.mean
        let slowGap = gybeCells.map { cell -> Double in
            let best = Helm.gybe.filter(\.countsForBest).compactMap { pick($0, .gybe, cell)?.loss30 }.min() ?? 0
            let linger = [Helm.linger2, .linger4].compactMap { pick($0, .gybe, cell)?.loss30 }.min() ?? best
            let quarter = pick(.rudder25, .gybe, cell)?.loss30 ?? best
            return max(linger, quarter) - best
        }.mean
        let deplaned = gybeCells.flatMap { cell in
            [Helm.linger2, .linger4, .rudder25].compactMap { pick($0, .gybe, cell)?.deplaned }
        }
        let deplaneRate = deplaned.isEmpty ? 0 : Double(deplaned.filter { $0 }.count) / Double(deplaned.count)
        let replaneTimes = gybeCells.flatMap { cell in
            [Helm.linger2, .linger4, .rudder25].compactMap { helm -> Double? in
                guard let m = pick(helm, .gybe, cell), m.deplaned else { return nil }
                return m.replane ?? 45
            }
        }
        let replane = replaneTimes.mean
        let deepCells = cells.filter { $0.knots == 10 && $0.entry == 1 }
        let steadyDeep = deepCells.filter { $0.seed == nil }
        let gustyDeep = deepCells.filter { $0.seed != nil }
        let vmg0 = steadyDeep.compactMap { pick(.deep0, .run, $0)?.vmg }.mean
        let vmg10 = steadyDeep.compactMap { pick(.deep10, .run, $0)?.vmg }.mean
        let vmgGain = vmg0 == 0 ? 0 : (vmg10 - vmg0) / vmg0
        let gustyFlags = gustyDeep.compactMap { pick(.deep10, .run, $0)?.deplaned }
        let gustyRate = gustyFlags.isEmpty ? 0 : Double(gustyFlags.filter { $0 }.count) / Double(gustyFlags.count)
        let deepCost = gustyDeep.compactMap { pick(.deep10, .run, $0)?.replaneCost }.mean
        let releaseCells = tackCells
        let stuck = releaseCells.flatMap { cell in
            [Helm.release25, .release60].compactMap { pick($0, .tack, cell)?.stuck }
        }.mean
        let rescue = releaseCells.flatMap { cell in
            [Helm.release25rescue, .release60rescue].compactMap { pick($0, .tack, cell)?.regain95 ?? 45 }
        }.mean
        let slamSpeeds = cells.filter { $0.maneuverSample }.flatMap { cell in
            [pick(.slam, .tack, cell)].compactMap { $0 }
        }
        let minSpeed = slamSpeeds.map(\.minSpeedRatio).min() ?? 1
        let maxDecel = slamSpeeds.map(\.maxDecel).max() ?? 0
        var card = Scorecard(bestTack: bestTack, slamTack: slamTack, gentle: gentle, light: light, strong: strong,
                             bestGybe: bestGybe, slowGybe: slowGap, replane: replane, vmgGain: vmgGain,
                             deepDeplane: gustyRate, deepCost: deepCost, stuck: stuck, rescue: rescue,
                             minSpeed: minSpeed, maxDecel: maxDecel, deplaneRate: deplaneRate)
        card.score = card.total(gybe: mode == .full || mode == .gustyOnly)
        return card
    }

    static func cells(_ mode: Mode) -> [Cell] {
        let knots = [6.0, 10.0, 14.0]
        let entries = [0.70, 0.85, 1.0]
        let seeds: [Int?] = mode == .gustyOnly ? [1, 2, 3, 4, 5, 6] : [nil, 1, 2, 3, 4, 5, 6]
        if mode == .tackGap {
            return seeds.map { Cell(knots: 10, entry: 1, seed: $0) }
        }
        return knots.flatMap { k in entries.flatMap { e in seeds.map { Cell(knots: k, entry: e, seed: $0) } } }
    }

    // MARK: - One run

    static func run(_ helm: Helm, _ maneuver: Maneuver, _ cell: Cell, params: SweepParams, boat: BoatClass,
                    book: WindBook, series: [(Double, Double)]? = nil,
                    twinSeries: [(Double, Double)]? = nil) throws -> RunMetrics {
        let seconds = helm.seconds(maneuver)
        let ticks = Int((seconds / dt).rounded())
        let groove: Autohelm.Groove = maneuver == .tack ? .upwind : .downwind
        let sampled0 = book.sample(knots: cell.knots, seed: cell.seed, tick: 0)
        let wind0: (direction: Double, speed: Double) = series?.first.map { (direction: $0.0, speed: $0.1) } ?? sampled0
        let angle = Autohelm.grooveAngle(groove, tws: wind0.speed, boatClass: boat)
        let boom = BoomSide.port
        let heading0 = compass(wind: wind0.direction, sailingAngle: angle, boom: boom)
        let relative = boom == .port ? angle : -angle
        let kite: Spinnaker = maneuver == .tack ? .down : .up
        let target = BoatDynamics.polarTarget(relativeWind: relative, boomSide: boom, tws: wind0.speed,
                                              isPlaning: maneuver != .tack, spinnaker: kite, boatClass: boat)
        let entrySpeed = cell.entry * target
        let twa = abs(angle)
        let onPlane = boat.planing.map { twa >= $0.offBelowTWA && entrySpeed >= $0.onSpeed } ?? false
        var helmState = BoatDynamics.State(position: .zero, heading: heading0, speed: entrySpeed, boomSide: boom,
                                           isPlaning: onPlane, spinnaker: kite)
        var twinState = helmState
        let tap = Autohelm.tackOrGybe(sailingAngle: angle)
        let signed = tap.rudder(sailingAngle: angle, boomSide: boom, tws: wind0.speed, boatClass: boat)
        let turnSign = signed >= 0 ? 1.0 : -1.0
        var pilot = Pilot(helm: helm, maneuver: maneuver)
        let along = maneuver == .tack ? Vec2.heading(wind0.direction) : -Vec2.heading(wind0.direction)
        var metrics = RunMetrics()
        var helmClock = ProbeClock()
        var twinClock = ProbeClock()
        var prevSpeed = entrySpeed
        var good95 = 0, good98 = 0
        var offAt: Int?
        var dropHelm: Vec2?, dropTwin: Vec2?
        let base = params.mechanics()
        for tick in 0..<ticks {
            let sampled = book.sample(knots: cell.knots, seed: cell.seed, tick: tick)
            let (dir, speed) = series.flatMap { tick < $0.count ? $0[tick] : nil } ?? sampled
            let (twinDir, twinSpeed) = twinSeries.flatMap { tick < $0.count ? $0[tick] : nil } ?? (dir, speed)
            let env = BoatDynamics.Environment(windDirection: dir, windSpeed: speed)
            let twinEnv = BoatDynamics.Environment(windDirection: twinDir, windSpeed: twinSpeed)
            let context = HelmContext(t: Double(tick) * dt, heading: helmState.heading, speed: helmState.speed,
                                      rudder: helmState.rudder, boom: helmState.boomSide, planing: helmState.isPlaning,
                                      windDir: dir, tws: speed, turnSign: turnSign, startBoom: boom, boat: boat,
                                      maneuver: maneuver == .tack ? .tack : .gybe)
            let command = pilot.command(context)
            let origin = compass(wind: twinDir, sailingAngle: Autohelm.grooveAngle(groove, tws: twinSpeed, boatClass: boat), boom: boom)
            let twinCommand = holdLaw(heading: twinState.heading, aim: origin)
            let aim = context.finalAim(offsetDeg: 0)
            var helmProbe = base
            let remaining = headingRemaining(from: helmState.heading, to: aim, turnSign: turnSign)
            helmProbe.degreesPastGroove = max(0, rad2deg(-remaining))
            helmProbe.aimErrorRadians = abs(wrapAngle(aim - helmState.heading))
            var twinProbe = base
            twinProbe.degreesPastGroove = 0
            twinProbe.aimErrorRadians = .pi
            if base.isOff {
                helmState = BoatDynamics.advance(helmState, control: .init(rudder: command), env: env, boatClass: boat, dt: dt)
                twinState = BoatDynamics.advance(twinState, control: .init(rudder: twinCommand), env: twinEnv, boatClass: boat, dt: dt)
            } else {
                helmState = BoatDynamics.advance(helmState, control: .init(rudder: command), env: env, boatClass: boat, dt: dt,
                                                probe: helmProbe, clock: &helmClock)
                twinState = BoatDynamics.advance(twinState, control: .init(rudder: twinCommand), env: twinEnv, boatClass: boat, dt: dt,
                                                probe: twinProbe, clock: &twinClock)
            }
            let t = Double(tick + 1) * dt
            let madeHelm = helmState.position.dot(along)
            let madeTwin = twinState.position.dot(along)
            let loss = (madeTwin - madeHelm) / hull
            if abs(t - 20) < dt / 2 { metrics.loss20 = loss }
            if abs(t - 25) < dt / 2 { metrics.loss25 = loss }
            if abs(t - 30) < dt / 2 { metrics.loss30 = loss }
            if abs(t - 45) < dt / 2 { metrics.loss45 = loss }
            if abs(t - 60) < dt / 2 { metrics.loss60 = loss }
            metrics.minSpeedRatio = min(metrics.minSpeedRatio, helmState.speed / max(entrySpeed, 1e-6))
            let decel = knots(metresPerSecond: (prevSpeed - helmState.speed) / dt)
            metrics.maxDecel = max(metrics.maxDecel, decel)
            prevSpeed = helmState.speed
            if metrics.boomCross == nil, helmState.boomSide != boom { metrics.boomCross = t }
            if metrics.timeToAim == nil, abs(wrapAngle(helmState.heading - aim)) < deg2rad(5) { metrics.timeToAim = t }
            let grooveTarget = BoatDynamics.polarTarget(
                relativeWind: context.newBoom == .port ? context.finalAngle : -context.finalAngle,
                boomSide: context.newBoom, tws: speed, isPlaning: helmState.isPlaning, spinnaker: helmState.spinnaker,
                boatClass: boat)
            let nowTWA = abs(wrapAngle(dir - helmState.heading))
            if helmState.speed < 0.3 * max(grooveTarget, 1e-6), nowTWA < BoatDynamics.noGoAngle(boat.polar) {
                metrics.stuck += dt
            }
            if helmState.speed >= 0.95 * grooveTarget { good95 += 1 } else { good95 = 0 }
            if helmState.speed >= 0.98 * grooveTarget { good98 += 1 } else { good98 = 0 }
            if metrics.regain95 == nil, good95 >= 60 { metrics.regain95 = t }
            if metrics.regain98 == nil, good98 >= 60 { metrics.regain98 = t }
            if onPlane, !helmState.isPlaning {
                if !metrics.deplaned { metrics.deplaned = true; offAt = tick; dropHelm = helmState.position; dropTwin = twinState.position }
                metrics.offPlane += dt
            } else if metrics.deplaned, metrics.replane == nil, helmState.isPlaning {
                metrics.replane = t - Double(offAt ?? tick) * dt
                if let dropHelm, let dropTwin {
                    let recovered = (twinState.position - dropTwin).dot(along) - (helmState.position - dropHelm).dot(along)
                    metrics.replaneCost += recovered / hull
                }
            }
        }
        if maneuver == .run {
            let down = -Vec2.heading(wind0.direction)
            metrics.vmg = helmState.position.dot(down) / seconds
        }
        return metrics
    }

    // MARK: - Benchmark and case

    static func benchmark(_ boat: BoatClass) -> (ns: Double, ticks: Int) {
        let tws = metresPerSecond(knots: 10)
        let angle = boat.polar.bestUpwind(tws: tws).twa
        var state = BoatDynamics.State(heading: -angle, speed: boat.polar.bestUpwind(tws: tws).speed, boomSide: .port)
        let env = BoatDynamics.Environment.constant(windDirection: 0, windSpeed: tws)
        let n = 30_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n {
            state = BoatDynamics.advance(state, control: .init(rudder: 1), env: env, boatClass: boat, dt: dt)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        print(String(format: "bench sink speed %.3f kn", knots(metresPerSecond: state.speed)))
        return (Double(elapsed) / Double(n), n)
    }

    static func runCase(_ name: String, options: Options, book: WindBook) throws {
        guard let helm = Helm(rawValue: name) else { throw SweepError.message("unknown helm \(name)") }
        let maneuver: Maneuver = options.maneuver == "gybe" ? .gybe : (options.maneuver == "run" ? .run : .tack)
        let cell = Cell(knots: options.knots, entry: options.entry, seed: nil)
        let metric = try run(helm, maneuver, cell, params: .stock, boat: try boatClass(.stock), book: book)
        print(String(format: "%@ %@ %.0f kn entry %.2f  L20 %.3f L25 %.3f L30 %.3f  minSpeed %.2f decel %.2f stuck %.1f",
                     helm.rawValue, maneuver.rawValue, cell.knots, cell.entry, metric.loss20, metric.loss25, metric.loss30,
                     metric.minSpeedRatio, metric.maxDecel, metric.stuck))
    }

    static func writeReport(book: WindBook) throws {
        let name = FileManager.default.fileExists(atPath: outDir.appendingPathComponent("refine-best.json").path)
            ? "refine-best.json" : "stage2-top.json"
        let rows = try loadRows(name)
        guard let best = rows.first else { throw SweepError.empty }
        var text = "# Tack sweep\n\n"
        text += "Score \(best.score)\n\n"
        text += best.card.table
        text += "\n\n## Parameters\n\n"
        text += best.params.lines
        try text.write(to: resultsDir.appendingPathComponent("loss-table.md"), atomically: true, encoding: .utf8)
        try text.write(to: outDir.appendingPathComponent("loss-table.md"), atomically: true, encoding: .utf8)
        print("wrote results/loss-table.md")
        _ = book
    }

    static func raceScore(_ params: SweepParams, jobs: Int) throws -> Scorecard {
        // Gusty race-level check of slam and the bear-away helms is filled in by the dynamics scorer's
        // gusty cells until the race loop below replaces slam. The race loop sails slam at 10 kn.
        var slamSum = 0.0
        var n = 0.0
        let boatFile = try tunedFile(params)
        for seed in 1...6 {
            let loss = try racePair(helm: .slam, seed: seed, knots: 10, entry: 1, file: boatFile, params: params)
            slamSum += loss
            n += 1
        }
        var card = Scorecard()
        card.slamTack = slamSum / max(n, 1)
        card.bestTack = card.slamTack
        _ = jobs
        return card
    }

    static func racePair(helm: Helm, seed: Int, knots wanted: Double, entry: Double, file: BoatClassFile,
                         params: SweepParams) throws -> Double {
        let conditions = try ConditionsFile.bundled(id: "gusty-offshore", version: 7)
        let venue = try VenueFile.bundled(id: "dev-venue", version: 7)
        func make() throws -> Race {
            var catalog = RaceFileCatalog()
            try catalog.boatClasses.add(file)
            let setup = try RaceSetup(raceSeed: RaceSeed(UInt64(seed)), seats: [.human, .human], laps: 1,
                                     startSequenceTicks: 1, boatClass: file.ref, venue: venue.ref,
                                     conditions: conditions.ref)
            return try Race(setup: setup, files: try RaceFiles(resolving: setup, from: catalog),
                           mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: UInt64(seed))))
        }
        let helmRace = try make()
        let twinRace = try make()
        helmRace.step()
        twinRace.step()
        func place(_ race: Race) throws {
            var snap = race.exportSnapshot()
            let wind = race.groundWind(at: snap.seats[0].boat.position)
            let boat = file.content
            let angle = Autohelm.grooveAngle(.upwind, tws: wind.speed, boatClass: boat)
            let area = race.course.raceArea
            snap.seats[0].boat.position = area.centre + race.course.right * (area.halfWidth * 0.4)
            snap.seats[0].boat.heading = compass(wind: wind.direction, sailingAngle: angle, boom: .port)
            let target = BoatDynamics.polarTarget(relativeWind: angle, boomSide: .port, tws: wind.speed,
                                                  isPlaning: false, spinnaker: .down, boatClass: boat)
            snap.seats[0].boat.speed = entry * target
            snap.seats[0].boat.boomSide = .port
            snap.seats[0].boat.rudder = 0
            snap.seats[0].boat.desiredRudder = 0
            snap.seats[0].boat.autohelm = nil
            snap.seats[0].heldInput = .neutral
            snap.seats[1].boat.position = area.centre - race.course.right * (area.halfWidth * 0.6)
            snap.seats[1].boat.speed = 0
            try race.importSnapshot(snap)
        }
        try place(helmRace)
        try place(twinRace)
        let session = ProbeSession(mechanics: params.mechanics())
        ProbeSlot.current = session
        defer { ProbeSlot.current = nil }
        let ticks = 25 * Race.tickRate
        let wind0 = helmRace.groundWind(at: helmRace.boats[0].position)
        let start = helmRace.boats[0].position
        let twinStart = twinRace.boats[0].position
        let boat = file.content
        let angle = Autohelm.grooveAngle(.upwind, tws: wind0.speed, boatClass: boat)
        let tap = Autohelm.tackOrGybe(sailingAngle: angle)
        let turnSign = tap.rudder(sailingAngle: angle, boomSide: .port, tws: wind0.speed, boatClass: boat) >= 0 ? 1.0 : -1.0
        var pilot = Pilot(helm: helm, maneuver: .tack)
        for _ in 0..<ticks {
            let wind = helmRace.groundWind(at: helmRace.boats[0].position)
            let b = helmRace.boats[0]
            let context = HelmContext(t: helmRace.time, heading: b.heading, speed: b.speed, rudder: b.rudder,
                                      boom: b.boomSide, planing: b.isPlaning, windDir: wind.direction, tws: wind.speed,
                                      turnSign: turnSign, startBoom: .port, boat: boat, maneuver: .tack)
            let aim = context.finalAim(offsetDeg: 0)
            let remaining = headingRemaining(from: b.heading, to: aim, turnSign: turnSign)
            session.mechanics.degreesPastGroove = max(0, rad2deg(-remaining))
            session.mechanics.aimErrorRadians = abs(wrapAngle(aim - b.heading))
            let command = pilot.command(context)
            helmRace.apply(BoatInput(rudder: command), seat: 0, atTick: helmRace.tick + 1)
            let twinWind = twinRace.groundWind(at: twinRace.boats[0].position)
            let origin = compass(wind: twinWind.direction,
                                sailingAngle: Autohelm.grooveAngle(.upwind, tws: twinWind.speed, boatClass: boat),
                                boom: .port)
            let hold = holdLaw(heading: twinRace.boats[0].heading, aim: origin)
            twinRace.apply(BoatInput(rudder: hold), seat: 0, atTick: twinRace.tick + 1)
            session.resetClocks()
            helmRace.step()
            session.mechanics.degreesPastGroove = 0
            session.mechanics.aimErrorRadians = .pi
            twinRace.step()
        }
        ProbeSlot.current = nil
        let along = Vec2.heading(wind0.direction)
        let helmMade = (helmRace.boats[0].position - start).dot(along)
        let twinMade = (twinRace.boats[0].position - twinStart).dot(along)
        return (twinMade - helmMade) / hull
    }

    // MARK: - Stage 5 (owner 2026-10-09)

    static func stage5(_ options: Options, book: WindBook) throws {
        let started = Date()
        guard let winner = try loadRows("refine-best.json").first else { throw SweepError.empty }
        let m1 = shipping(winner.params, lag: false)
        let m1m3 = shipping(winner.params, lag: true)
        print("Stage 5: planing and by-the-lee reset to skiff@7")
        let cardA = try score(m1, book: book, mode: .full, jobs: options.jobs)
        let cardB = try score(m1m3, book: book, mode: .full, jobs: options.jobs)
        print(String(format: "(a) M1 only  score %.3f", cardA.score))
        print(cardA.table)
        print(String(format: "(b) M1+M3    score %.3f  lag %.3f s", cardB.score, m1m3.driveLagSeconds))
        print(cardB.table)
        var ship = m1
        var shipCard = cardA
        if gybeOffTarget(cardA) {
            print("Gybe term off target with planing reset. Refining steering and momentum; planing stays at skiff@7.")
            let refined = try refine(m1, knobs: Array(SweepParams.knobs.prefix(9)), book: book, jobs: options.jobs)
            ship = refined.params
            shipCard = refined.card
            print(String(format: "Refined shipping score %.3f", shipCard.score))
            print(shipCard.table)
            print(ship.lines)
        } else {
            print("Gybe terms 6 and 7 hold with planing reset. Shipping set is (a), no steering refine.")
        }
        try lossTable(ship, book: book, jobs: options.jobs)
        try stuckSensitivity(ship, book: book, jobs: options.jobs)
        try raceConfirm(ship, book: book, jobs: options.jobs)
        print(String(format: "Stage 5 wall %.0f s", Date().timeIntervalSince(started)))
        _ = shipCard
    }

    static func shipping(_ base: SweepParams, lag: Bool) -> SweepParams {
        var p = base
        p.onSpeed = 8
        p.offSpeed = 6
        p.onMaxAWA = 90
        p.byTheLeeLoss = 0.02
        p.collapse = 10
        p.byTheLeeLimit = 20
        p.dragExponent = 2
        p.dragTurnRateTerm = 0
        p.overshootCost = 0
        p.windBandDegrees = 0
        p.windBandRateFactor = 1
        p.settleDegrees = 0
        p.settleBonus = 0
        p.driveLagSeconds = lag ? base.driveLagSeconds : 0
        p.dePlaneRampSeconds = 0
        p.byTheLeeExponent = 1
        return p
    }

    static func gybeOffTarget(_ card: Scorecard) -> Bool {
        abs(card.bestGybe - 1.10) > 0.14 || card.slowGybe < 0.6 || card.slowGybe > 1.5
    }

    static func lossTable(_ params: SweepParams, book: WindBook, jobs: Int) throws {
        let boat = try boatClass(params)
        struct Item: Sendable { var helm: Helm; var maneuver: Maneuver; var cell: Cell }
        var items: [Item] = []
        for knots in [6.0, 10.0, 14.0] {
            for entry in [0.70, 0.85, 1.0] {
                for seed in [Int?]( [nil, 1, 2, 3, 4, 5, 6] ) {
                    let cell = Cell(knots: knots, entry: entry, seed: seed)
                    for helm in Helm.tack { items.append(Item(helm: helm, maneuver: .tack, cell: cell)) }
                    for helm in Helm.gybe { items.append(Item(helm: helm, maneuver: .gybe, cell: cell)) }
                }
            }
        }
        let metrics = try inParallel(items, jobs: jobs) { item in
            try run(item.helm, item.maneuver, item.cell, params: params, boat: boat, book: book)
        }
        var buckets: [String: [Double]] = [:]
        for (item, metric) in zip(items, metrics) {
            let loss = item.maneuver == .gybe ? metric.loss30 : metric.loss25
            let key = "\(item.helm.rawValue)|\(item.maneuver.rawValue)|\(item.cell.knots)|\(item.cell.entry)"
            buckets[key, default: []].append(loss)
        }
        var text = "# Loss table, shipping set\n\nMean over steady and gusty seeds 1–6. Tack window 25 s, gybe window 30 s.\n\n"
        text += "| helm | maneuver | wind kn | entry | L |\n|---|---|---:|---:|---:|\n"
        let helms = Helm.tack.map { ($0, Maneuver.tack) } + Helm.gybe.map { ($0, Maneuver.gybe) }
        for (helm, maneuver) in helms {
            for knots in [6.0, 10.0, 14.0] {
                for entry in [0.70, 0.85, 1.0] {
                    let key = "\(helm.rawValue)|\(maneuver.rawValue)|\(knots)|\(entry)"
                    let values = buckets[key] ?? []
                    let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
                    text += String(format: "| %@ | %@ | %.0f | %.2f | %.3f |\n", helm.rawValue, maneuver.rawValue, knots, entry, mean)
                }
            }
        }
        try text.write(to: resultsDir.appendingPathComponent("loss-table.md"), atomically: true, encoding: .utf8)
        try text.write(to: outDir.appendingPathComponent("loss-table.md"), atomically: true, encoding: .utf8)
        print("wrote results/loss-table.md (\(helms.count) helms)")
    }

    static func stuckSensitivity(_ params: SweepParams, book: WindBook, jobs: Int) throws {
        let axes: [(String, WritableKeyPath<SweepParams, Double>, [Double])] = [
            ("headToWindFallOff", \.fallOff, [1, 2, 3, 4, 6]),
            ("noGo", \.noGo, [2.5, 4, 4.8, 5.79, 8]),
            ("rudderSlew", \.rudderSlew, [2, 4, 5, 8, 10]),
        ]
        print("Stuck sensitivity (tack terms, one at a time from the shipping set)")
        var lines = ["| knob | value | stuck s | best | slam | gentle | light | strong | holds |",
                     "|---|---:|---:|---:|---:|---:|---:|---:|---|"]
        for (name, path, values) in axes {
            for value in values {
                var trial = params
                trial[keyPath: path] = value
                let card = try score(trial, book: book, mode: .tack, jobs: jobs)
                let holds = tackHolds(card)
                let mark = abs(value - params[keyPath: path]) < 1e-6 ? " (ship)" : ""
                print(String(format: "  %@ %.2f%@  stuck %.2f  best %.3f slam %.3f gentle %.3f light %.3f strong %.3f  %@",
                             name, value, mark, card.stuck, card.bestTack, card.slamTack, card.gentle, card.light, card.strong,
                             holds && card.stuck < 10 ? "under 10s, tack holds" : (card.stuck < 10 ? "under 10s, tack breaks" : "stuck stays over 10s")))
                lines.append(String(format: "| %@ | %.2f%@ | %.2f | %.3f | %.3f | %.3f | %.3f | %.3f | %@ |",
                                    name, value, mark, card.stuck, card.bestTack, card.slamTack, card.gentle, card.light, card.strong,
                                    holds ? "yes" : "no"))
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: resultsDir.appendingPathComponent("stuck.md"), atomically: true, encoding: .utf8)
        print("wrote results/stuck.md")
    }

    static func tackHolds(_ card: Scorecard) -> Bool {
        abs(card.bestTack - 0.95) < 0.15 && abs(card.slamTack - 1.10) < 0.15 && card.gentle <= 0.7
            && card.light >= 0.25 && card.minSpeed >= 0.4 && card.maxDecel <= 4
    }

    static func raceConfirm(_ params: SweepParams, book: WindBook, jobs: Int) throws {
        print("Race confirm: same race, sail-on reference, TWS set to the cell")
        try explainSignFlip(params)
        let boat = try boatClass(params)
        for knots in [10.0, 14.0] {
            let best = try bestTackHelm(params, knots: knots, boat: boat, book: book, jobs: jobs)
            print(String(format: "  %.0f kn best helm %@", knots, best.rawValue))
            struct Job: Sendable { var seed: Int; var helm: Helm }
            let jobsList = (1...6).flatMap { seed in [Job(seed: seed, helm: .slam), Job(seed: seed, helm: best)] }
            let rows = try inParallel(jobsList, jobs: jobs) { job -> (Job, Double, Double, Double) in
                let cell = Cell(knots: knots, entry: 1, seed: job.seed)
                let harness = try run(job.helm, .tack, cell, params: params, boat: boat, book: book).loss25
                let pair = try raceVersusReference(job.helm, seed: job.seed, knots: knots, entry: 1, params: params)
                return (job, harness, pair.race, pair.point)
            }
            for helm in [Helm.slam, best] {
                let mine = rows.filter { $0.0.helm == helm }
                let h = mine.map(\.1).mean
                let r = mine.map(\.2).mean
                let p = mine.map(\.3).mean
                print(String(format: "  %.0f kn %@  harness %.3f  race %.3f  point-wind %.3f  race-harness %+.3f",
                             knots, helm.rawValue, h, r, p, r - h))
                for row in mine.sorted(by: { $0.0.seed < $1.0.seed }) {
                    print(String(format: "    seed %d  harness %.3f  race %.3f  point %.3f",
                                 row.0.seed, row.1, row.2, row.3))
                }
            }
        }
    }

    static func bestTackHelm(_ params: SweepParams, knots: Double, boat: BoatClass, book: WindBook, jobs: Int) throws -> Helm {
        let helms = Helm.tack.filter(\.countsForBest)
        struct Item: Sendable { var helm: Helm; var seed: Int }
        let items = helms.flatMap { helm in (1...6).map { Item(helm: helm, seed: $0) } }
        let losses = try inParallel(items, jobs: jobs) { item -> Double in
            try run(item.helm, .tack, Cell(knots: knots, entry: 1, seed: item.seed), params: params, boat: boat, book: book).loss25
        }
        var sum: [Helm: Double] = [:]
        var n: [Helm: Double] = [:]
        for (item, loss) in zip(items, losses) {
            sum[item.helm, default: 0] += loss
            n[item.helm, default: 0] += 1
        }
        return helms.min { (sum[$0] ?? 0) / (n[$0] ?? 1) < (sum[$1] ?? 0) / (n[$1] ?? 1) } ?? .slam
    }

    static func explainSignFlip(_ params: SweepParams) throws {
        let file = try tunedFile(params)
        let race = try makeRace(file: file, knots: nil, seed: 1)
        race.step()
        let origin = race.boats[0].position
        let windThere = race.groundWind(at: origin)
        let area = race.course.raceArea
        let moved = area.centre + race.course.right * (area.halfWidth * 0.4)
        let windMoved = race.groundWind(at: moved)
        let turn = rad2deg(wrapAngle(windMoved.direction - windThere.direction))
        print(String(format: "Sign flip: stage 4 aimed on the wind at the boat's start (%.1f kn) then measured along the wind after moving her across the course (%.1f kn, direction %+.1f deg). It also left gusty-offshore at its file strength, 14–20 kn, while the dynamics number was the same gust shape scaled to 10 kn. The race and the dynamics were not the same wind.",
                     knots(metresPerSecond: windThere.speed), knots(metresPerSecond: windMoved.speed), turn))
    }

    static func raceVersusReference(_ helm: Helm, seed: Int, knots wanted: Double, entry: Double,
                                    params: SweepParams) throws -> (race: Double, point: Double) {
        let file = try tunedFile(params)
        let race = try makeRace(file: file, knots: wanted, seed: seed)
        race.step()
        let area = race.course.raceArea
        let boat = file.content
        let spot = area.centre + race.course.right * (area.halfWidth * 0.4)
        let gap = boat.hull.length * 12
        let helmPos = spot + race.course.right * (gap / 2)
        let twinPos = spot - race.course.right * (gap / 2)
        let wind = race.groundWind(at: helmPos)
        let angle = Autohelm.grooveAngle(.upwind, tws: wind.speed, boatClass: boat)
        let heading = compass(wind: wind.direction, sailingAngle: angle, boom: .port)
        let target = BoatDynamics.polarTarget(relativeWind: angle, boomSide: .port, tws: wind.speed,
                                              isPlaning: false, spinnaker: .down, boatClass: boat)
        var snap = race.exportSnapshot()
        for (seat, position) in [(0, helmPos), (1, twinPos)] {
            snap.seats[seat].boat.position = position
            snap.seats[seat].boat.heading = heading
            snap.seats[seat].boat.speed = entry * target
            snap.seats[seat].boat.boomSide = .port
            snap.seats[seat].boat.rudder = 0
            snap.seats[seat].boat.desiredRudder = 0
            snap.seats[seat].boat.autohelm = nil
            snap.seats[seat].heldInput = .neutral
            snap.seats[seat].boat.isPlaning = false
            snap.seats[seat].boat.spinnaker = .down
        }
        try race.importSnapshot(snap)
        let session = ProbeSession(mechanics: params.mechanics())
        ProbeSlot.current = session
        defer { ProbeSlot.current = nil }
        let ticks = 25 * Race.tickRate
        let start0 = race.boats[0].position
        let start1 = race.boats[1].position
        let along = Vec2.heading(wind.direction)
        let tap = Autohelm.tackOrGybe(sailingAngle: angle)
        let turnSign = tap.rudder(sailingAngle: angle, boomSide: .port, tws: wind.speed, boatClass: boat) >= 0 ? 1.0 : -1.0
        var pilot = Pilot(helm: helm, maneuver: .tack)
        var helmSeries: [(Double, Double)] = []
        var twinSeries: [(Double, Double)] = []
        helmSeries.reserveCapacity(ticks)
        twinSeries.reserveCapacity(ticks)
        for _ in 0..<ticks {
            let helmWind = race.groundWind(at: race.boats[0].position)
            let twinWind = race.groundWind(at: race.boats[1].position)
            helmSeries.append((helmWind.direction, helmWind.speed))
            twinSeries.append((twinWind.direction, twinWind.speed))
            let b = race.boats[0]
            let context = HelmContext(t: race.time, heading: b.heading, speed: b.speed, rudder: b.rudder,
                                      boom: b.boomSide, planing: b.isPlaning, windDir: helmWind.direction, tws: helmWind.speed,
                                      turnSign: turnSign, startBoom: .port, boat: boat, maneuver: .tack)
            race.apply(BoatInput(rudder: pilot.command(context)), seat: 0, atTick: race.tick + 1)
            let origin = compass(wind: twinWind.direction,
                                sailingAngle: Autohelm.grooveAngle(.upwind, tws: twinWind.speed, boatClass: boat),
                                boom: .port)
            let hold = holdLaw(heading: race.boats[1].heading, aim: origin)
            race.apply(BoatInput(rudder: hold), seat: 1, atTick: race.tick + 1)
            race.step()
        }
        let raceLoss = ((race.boats[1].position - start1).dot(along) - (race.boats[0].position - start0).dot(along)) / hull
        let point = try run(helm, .tack, Cell(knots: wanted, entry: entry, seed: seed), params: params, boat: boat,
                           book: WindBook(series: [:], offset: [:]), series: helmSeries, twinSeries: twinSeries).loss25
        return (raceLoss, point)
    }

    static func makeRace(file: BoatClassFile, knots wanted: Double?, seed: Int) throws -> Race {
        let venue = try VenueFile.bundled(id: "dev-venue", version: 7)
        var catalog = RaceFileCatalog()
        try catalog.boatClasses.add(file)
        let conditions: ConditionsFile
        if let wanted {
            guard let data = try ConditionsFile.bundledData(id: "gusty-offshore", version: 7) else {
                throw SweepError.message("gusty-offshore@7 is not bundled")
            }
            conditions = try TunedCopy.make(Conditions.self, base: data, values: [
                "/strength/minKnots": wanted,
                "/strength/maxKnots": wanted,
            ], tune: 1).file
            try catalog.conditions.add(conditions)
        } else {
            conditions = try ConditionsFile.bundled(id: "gusty-offshore", version: 7)
        }
        let setup = try RaceSetup(raceSeed: RaceSeed(UInt64(seed)), seats: [.human, .human], laps: 1,
                                 startSequenceTicks: 1, boatClass: file.ref, venue: venue.ref,
                                 conditions: conditions.ref)
        return try Race(setup: setup, files: try RaceFiles(resolving: setup, from: catalog),
                       mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: UInt64(seed))))
    }
}

// MARK: - Types

enum Maneuver: String, Sendable { case tack, gybe, run }

enum Helm: String, CaseIterable, Sendable {
    case slam, rudder75, rudder50, rudder25
    case smooth20, smooth35
    case over5, over10, over20, under5, under10, under20
    case release25, release60, release25rescue, release60rescue
    case bear10x3, bear10x5, bear15x3, bear15x5
    case linger2, linger4
    case deep0, deep5, deep10, deep15

    static var tack: [Helm] { allCases.filter { !$0.isGybeOnly && !$0.isDeep } }
    static var gybe: [Helm] { allCases.filter { !$0.isTackOnly && !$0.isDeep } }
    static var deep: [Helm] { allCases.filter(\.isDeep) }
    static var bear: [Helm] { [.bear10x3, .bear10x5, .bear15x3, .bear15x5] }

    var isTackOnly: Bool {
        switch self {
        case .bear10x3, .bear10x5, .bear15x3, .bear15x5: true
        default: false
        }
    }
    var isGybeOnly: Bool {
        switch self { case .linger2, .linger4: true; default: false }
    }
    var isDeep: Bool {
        switch self { case .deep0, .deep5, .deep10, .deep15: true; default: false }
    }
    var countsForBest: Bool {
        switch self {
        case .release25, .release60, .release25rescue, .release60rescue: false
        default: !isDeep
        }
    }
    var fraction: Double {
        switch self {
        case .rudder75: 0.75
        case .rudder50: 0.50
        case .rudder25: 0.25
        default: 1
        }
    }
    func seconds(_ maneuver: Maneuver) -> Double {
        if isDeep { return 60 }
        switch self {
        case .release25, .release60, .release25rescue, .release60rescue: return 45
        default: return maneuver == .gybe ? 30 : 25
        }
    }
}

struct Cell: Sendable, Hashable {
    var knots: Double
    var entry: Double
    var seed: Int?
    var key: String { "\(knots)-\(entry)-\(seed.map(String.init) ?? "steady")" }
    var maneuverSample: Bool { knots == 10 && entry == 1 }
}

struct RunMetrics: Sendable {
    var loss20 = 0.0
    var loss25 = 0.0
    var loss30 = 0.0
    var loss45 = 0.0
    var loss60 = 0.0
    var minSpeedRatio = 1.0
    var maxDecel = 0.0
    var boomCross: Double?
    var timeToAim: Double?
    var stuck = 0.0
    var regain95: Double?
    var regain98: Double?
    var deplaned = false
    var offPlane = 0.0
    var replane: Double?
    var vmg = 0.0
    var replaneCost = 0.0
}

struct Scorecard: Codable, Sendable {
    var bestTack = 0.0
    var slamTack = 0.0
    var gentle = 0.0
    var light = 0.0
    var strong = 0.0
    var bestGybe = 0.0
    var slowGybe = 0.0
    var replane = 0.0
    var vmgGain = 0.0
    var deepDeplane = 0.0
    var deepCost = 0.0
    var stuck = 0.0
    var rescue = 0.0
    var minSpeed = 1.0
    var maxDecel = 0.0
    var deplaneRate = 0.0
    var score = 0.0

    static var header: String {
        "bestTack,slamTack,gentle,light,strong,bestGybe,slowGybe,replane,vmg,deepDeplane,deepCost,stuck,rescue,minSpeed,maxDecel,deplaneRate"
    }
    var csv: String {
        [bestTack, slamTack, gentle, light, strong, bestGybe, slowGybe, replane, vmgGain, deepDeplane, deepCost,
         stuck, rescue, minSpeed, maxDecel, deplaneRate].map { String($0) }.joined(separator: ",")
    }
    var table: String {
        """
        | k | measure | value |
        |---|---|---|
        | 1 | best tack L | \(bestTack) |
        | 2 | slam tack L | \(slamTack) |
        | 3 | gentle gap | \(gentle) |
        | 4 | light-air bearoff gap | \(light) |
        | 5 | strong-air bearoff gap | \(strong) |
        | 6 | best gybe L | \(bestGybe) |
        | 7 | slow gybe gap | \(slowGybe) |
        | 8 | re-plane s | \(replane) |
        | 9 | VMG gain / de-plane / cost | \(vmgGain) / \(deepDeplane) / \(deepCost) |
        | 10 | stuck / rescue | \(stuck) / \(rescue) |
        | 11 | min speed / decel | \(minSpeed) / \(maxDecel) |
        """
    }

    mutating func total(gybe: Bool) -> Double {
        func point(_ m: Double, _ t: Double, _ s: Double) -> Double { let d = (m - t) / s; return d * d }
        func lower(_ m: Double, _ lo: Double, _ s: Double) -> Double { let d = max(0, lo - m) / s; return d * d }
        func upper(_ m: Double, _ hi: Double, _ s: Double) -> Double { let d = max(0, m - hi) / s; return d * d }
        func band(_ m: Double, _ lo: Double, _ hi: Double, _ s: Double) -> Double {
            let d = max(0, m - hi, lo - m) / s
            return d * d
        }
        func gentleGap(_ m: Double) -> Double {
            if m <= 0.5 { return 0 }
            let d = (m - 0.5) / 0.1
            return m <= 0.7 ? d * d * 0.25 : d * d
        }
        var s = 3 * point(bestTack, 0.95, 0.05) + 3 * point(slamTack, 1.10, 0.05) + 2 * gentleGap(gentle)
        s += 3 * lower(light, 0.25, 0.1) + 3 * lower(strong, 0.15, 0.1)
        s += 2 * upper(stuck, 10, 3) + 2 * upper(rescue, 25, 3)
        s += 2 * lower(minSpeed, 0.4, 0.05) + 2 * upper(maxDecel, 4, 0.5)
        guard gybe else { return s }
        s += 3 * point(bestGybe, 1.10, 0.07) + 2 * band(slowGybe, 0.6, 1.5, 0.15)
        s += 2 * lower(deplaneRate, 1, 0.25)
        s += 1 * upper(replane, 20, 5)
        s += 1 * band(vmgGain, 0.03, 0.06, 0.01) + 1 * lower(deepDeplane, 0.20, 0.10) + 1 * lower(deepCost, 1.5, 0.5)
        return s
    }
}

struct SweepParams: Codable, Sendable, Equatable {
    var rudderDrag = 0.25
    var topTurnRate = 36.0
    var minTurnRate = 10.0
    var fullSteerKnots = 1.5
    var speedingUp = 2.5
    var noGo = 4.8
    var slowingDown = 10.0
    var rudderSlew = 5.0
    var fallOff = 3.0
    var onSpeed = 8.0
    var offSpeed = 6.0
    var onMaxAWA = 90.0
    var byTheLeeLoss = 0.02
    var collapse = 10.0
    var byTheLeeLimit = 20.0
    var dragExponent = 1.0
    var dragTurnRateTerm = 0.0
    var overshootCost = 0.0
    var windBandDegrees = 0.0
    var windBandRateFactor = 1.0
    var settleDegrees = 0.0
    var settleBonus = 0.0
    var driveLagSeconds = 0.0
    var dePlaneRampSeconds = 0.0
    var byTheLeeExponent = 1.0

    static var stock: SweepParams { SweepParams() }

    static func limit(_ name: String) -> SweepParams {
        var p = SweepParams()
        switch name {
        case "M1": p.dragExponent = 3; p.dragTurnRateTerm = 1; p.overshootCost = 1
        case "M2": p.windBandDegrees = 40; p.windBandRateFactor = 0.4
        case "M3": p.settleDegrees = 15; p.settleBonus = 1; p.driveLagSeconds = 3
        case "M4": p.dePlaneRampSeconds = 6; p.byTheLeeExponent = 3
        default: break
        }
        return p
    }

    var valid: Bool { offSpeed <= onSpeed && offSpeed > 0 && onSpeed > 0 }

    mutating func forceOff(_ mask: Int) {
        if mask & 1 == 0 { dragExponent = 1; dragTurnRateTerm = 0; overshootCost = 0 }
        if mask & 2 == 0 { windBandDegrees = 0; windBandRateFactor = 1 }
        if mask & 4 == 0 { settleDegrees = 0; settleBonus = 0; driveLagSeconds = 0 }
        if mask & 8 == 0 { dePlaneRampSeconds = 0; byTheLeeExponent = 1 }
    }

    func mechanics() -> ProbeMechanics {
        var m = ProbeMechanics()
        m.dragExponent = dragExponent
        m.dragTurnRateTerm = dragTurnRateTerm
        m.overshootCost = overshootCost
        m.windBandRadians = deg2rad(windBandDegrees)
        m.windBandRateFactor = windBandRateFactor
        m.settleRadians = deg2rad(settleDegrees)
        m.settleBonus = settleBonus
        m.driveLagSeconds = driveLagSeconds
        m.dePlaneRampSeconds = dePlaneRampSeconds
        m.byTheLeeExponent = byTheLeeExponent
        return m
    }

    func pointers() -> [String: Double] {
        [
            "/steering/rudderDragPerSecond": rudderDrag,
            "/steering/topTurnRateDegreesPerSecond": topTurnRate,
            "/steering/minTurnRateDegreesPerSecond": minTurnRate,
            "/steering/turnRateCurve/1/speedKnots": fullSteerKnots,
            "/momentum/speedingUpSeconds": speedingUp,
            "/momentum/noGoSeconds": noGo,
            "/momentum/slowingDownSeconds": slowingDown,
            "/steering/rudderSlewPerSecond": rudderSlew,
            "/steering/headToWindFallOffDegreesPerSecond": fallOff,
            "/planing/onSpeedKnots": onSpeed,
            "/planing/offSpeedKnots": offSpeed,
            "/planing/onMaxAWADegrees": onMaxAWA,
            "/byTheLee/speedLossPerDegree": byTheLeeLoss,
            "/byTheLee/spinnakerCollapseDegrees": collapse,
            "/polar/byTheLeeLimit/0/degrees": byTheLeeLimit,
        ]
    }

    static var header: String {
        "rudderDrag,topTurn,minTurn,fullSteer,speedingUp,noGo,slowingDown,slew,fallOff,onSpeed,offSpeed,awa,leeLoss,collapse,leeLimit,p,k,c,band,factor,settle,bonus,lag,ramp,exp"
    }
    var csv: String {
        [rudderDrag, topTurnRate, minTurnRate, fullSteerKnots, speedingUp, noGo, slowingDown, rudderSlew, fallOff,
         onSpeed, offSpeed, onMaxAWA, byTheLeeLoss, collapse, byTheLeeLimit, dragExponent, dragTurnRateTerm,
         overshootCost, windBandDegrees, windBandRateFactor, settleDegrees, settleBonus, driveLagSeconds,
         dePlaneRampSeconds, byTheLeeExponent].map { String($0) }.joined(separator: ",")
    }
    var lines: String { pointers().sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") }

    static var knobs: [Knob] {
        [
            Knob(\.rudderDrag, 0.10, 0.60, 0.05),
            Knob(\.topTurnRate, 24, 48, 4),
            Knob(\.minTurnRate, 4, 16, 2),
            Knob(\.fullSteerKnots, 1.5, 7, 0.5),
            Knob(\.speedingUp, 1.5, 4.5, 0.5),
            Knob(\.noGo, 2.5, 8, 0.5),
            Knob(\.slowingDown, 4, 14, 2),
            Knob(\.rudderSlew, 2, 10, 1),
            Knob(\.fallOff, 1, 6, 1),
            Knob(\.onSpeed, 6, 10, 1),
            Knob(\.offSpeed, 4, 8, 1),
            Knob(\.onMaxAWA, 80, 105, 5),
            Knob(\.byTheLeeLoss, 0.01, 0.05, 0.005),
            Knob(\.collapse, 6, 16, 2),
            Knob(\.byTheLeeLimit, 12, 30, 2),
            Knob(\.dragExponent, 1, 3, 0.5, bit: 0),
            Knob(\.dragTurnRateTerm, 0, 1, 0.25, bit: 0),
            Knob(\.overshootCost, 0, 1, 0.25, bit: 0),
            Knob(\.windBandDegrees, 0, 40, 10, bit: 1),
            Knob(\.windBandRateFactor, 0.4, 1, 0.15, bit: 1),
            Knob(\.settleDegrees, 0, 15, 3, bit: 2),
            Knob(\.settleBonus, 0, 1, 0.25, bit: 2),
            Knob(\.driveLagSeconds, 0, 3, 0.5, bit: 2),
            Knob(\.dePlaneRampSeconds, 0, 6, 1, bit: 3),
            Knob(\.byTheLeeExponent, 1, 3, 0.5, bit: 3),
        ]
    }
}

struct Knob {
    var path: WritableKeyPath<SweepParams, Double>
    var lo, hi, step: Double
    var mechanicBit: Int
    init(_ path: WritableKeyPath<SweepParams, Double>, _ lo: Double, _ hi: Double, _ step: Double, bit: Int = -1) {
        self.path = path
        self.lo = lo
        self.hi = hi
        self.step = step
        self.mechanicBit = bit
    }
    func forcedOff(_ mask: Int) -> Bool { mechanicBit >= 0 && mask & (1 << mechanicBit) == 0 }
}

struct HelmContext {
    var t: Double
    var heading: Double
    var speed: Double
    var rudder: Double
    var boom: BoomSide
    var planing: Bool
    var windDir: Double
    var tws: Double
    var turnSign: Double
    var startBoom: BoomSide
    var boat: BoatClass
    var maneuver: Maneuver

    var newBoom: BoomSide { startBoom.opposite }
    var grooveKind: Autohelm.Groove { maneuver == .tack ? .upwind : .downwind }
    var finalAngle: Double { Autohelm.grooveAngle(grooveKind, tws: tws, boatClass: boat) }
    func finalAim(offsetDeg: Double) -> Double {
        compass(wind: windDir, sailingAngle: finalAngle + deg2rad(offsetDeg), boom: newBoom)
    }
    var startAngle: Double { Autohelm.grooveAngle(grooveKind, tws: tws, boatClass: boat) }
}

struct Pilot {
    var helm: Helm
    var maneuver: Maneuver
    var phase = 0
    var mark = 0.0
    var initialRemaining = 0.0
    var captured = false

    mutating func command(_ x: HelmContext) -> Double {
        if helm.isDeep { return deep(x) }
        let aim = x.finalAim(offsetDeg: 0)
        let remaining = headingRemaining(from: x.heading, to: aim, turnSign: x.turnSign)
        if !captured { initialRemaining = max(remaining, 1e-6); captured = true }
        switch helm {
        case .slam, .rudder75, .rudder50, .rudder25:
            return held(x, aim: aim, magnitude: helm.fraction)
        case .smooth20, .smooth35:
            return smooth(x, ease: helm == .smooth20 ? 20 : 35)
        case .over5, .over10, .over20, .under5, .under10, .under20:
            return over(x)
        case .release25, .release60, .release25rescue, .release60rescue:
            return release(x, remaining: remaining)
        case .bear10x3, .bear10x5, .bear15x3, .bear15x5:
            return bear(x)
        case .linger2, .linger4:
            return linger(x)
        default:
            return 0
        }
    }

    func held(_ x: HelmContext, aim: Double, magnitude: Double) -> Double {
        let remaining = headingRemaining(from: x.heading, to: aim, turnSign: x.turnSign)
        let lead = abs(magnitude) * x.boat.steering.turnRate(speed: x.speed) * 0.2
        if remaining < lead { return holdLaw(heading: x.heading, aim: aim) }
        return quantise(x.turnSign * magnitude)
    }

    func smooth(_ x: HelmContext, ease: Double) -> Double {
        let aim = x.finalAim(offsetDeg: 0)
        let remaining = headingRemaining(from: x.heading, to: aim, turnSign: x.turnSign)
        let start = deg2rad(ease)
        let five = deg2rad(5)
        if remaining > start { return quantise(x.turnSign) }
        if remaining > five {
            let t = (start - remaining) / (start - five)
            return quantise(x.turnSign * (1 + (0.25 - 1) * t))
        }
        return holdLaw(heading: x.heading, aim: aim)
    }

    mutating func over(_ x: HelmContext) -> Double {
        let deg: Double
        let past: Bool
        switch helm {
        case .over5: deg = 5; past = true
        case .over10: deg = 10; past = true
        case .over20: deg = 20; past = true
        case .under5: deg = 5; past = false
        case .under10: deg = 10; past = false
        case .under20: deg = 20; past = false
        default: deg = 0; past = true
        }
        let sign: Double = x.maneuver == .tack ? 1 : -1
        let offset = (past ? sign : -sign) * deg
        let offsetAim = x.finalAim(offsetDeg: offset)
        let final = x.finalAim(offsetDeg: 0)
        if phase == 0 {
            let remaining = headingRemaining(from: x.heading, to: offsetAim, turnSign: x.turnSign)
            let lead = x.boat.steering.turnRate(speed: x.speed) * 0.2
            if remaining < lead { phase = 1; mark = x.t + 3; return holdLaw(heading: x.heading, aim: offsetAim) }
            return quantise(x.turnSign)
        }
        if phase == 1 {
            if x.t >= mark { phase = 2 }
            return holdLaw(heading: x.heading, aim: offsetAim)
        }
        return holdLaw(heading: x.heading, aim: final)
    }

    func release(_ x: HelmContext, remaining: Double) -> Double {
        let fraction = helm == .release25 || helm == .release25rescue ? 0.25 : 0.60
        let done = (initialRemaining - remaining) / initialRemaining
        if done < fraction { return quantise(x.turnSign) }
        let rescue = helm == .release25rescue || helm == .release60rescue
        if rescue, x.t >= 6 { return holdLaw(heading: x.heading, aim: x.finalAim(offsetDeg: 0)) }
        return 0
    }

    mutating func bear(_ x: HelmContext) -> Double {
        let (beta, hold): (Double, Double) = switch helm {
        case .bear10x3: (10, 3)
        case .bear10x5: (10, 5)
        case .bear15x3: (15, 3)
        case .bear15x5: (15, 5)
        default: (10, 3)
        }
        let away = -x.turnSign
        let bearAim = compass(wind: x.windDir, sailingAngle: x.startAngle + deg2rad(beta), boom: x.startBoom)
        if phase == 0 {
            let remaining = headingRemaining(from: x.heading, to: bearAim, turnSign: away)
            let lead = x.boat.steering.turnRate(speed: x.speed) * 0.2
            if remaining < lead { phase = 1; mark = x.t + hold }
            return quantise(away)
        }
        if phase == 1 {
            if x.t >= mark { phase = 2 }
            return holdLaw(heading: x.heading, aim: bearAim)
        }
        return held(x, aim: x.finalAim(offsetDeg: 0), magnitude: 1)
    }

    mutating func linger(_ x: HelmContext) -> Double {
        let hold: Double = helm == .linger2 ? 2 : 4
        let lee = compass(wind: x.windDir, sailingAngle: -.pi + deg2rad(5), boom: x.startBoom)
        if phase == 0 {
            let remaining = headingRemaining(from: x.heading, to: lee, turnSign: x.turnSign)
            let lead = x.boat.steering.turnRate(speed: x.speed) * 0.2
            if remaining < lead { phase = 1; mark = x.t + hold }
            return quantise(x.turnSign)
        }
        if phase == 1 {
            if x.t >= mark { phase = 2 }
            return holdLaw(heading: x.heading, aim: lee)
        }
        return held(x, aim: x.finalAim(offsetDeg: 0), magnitude: 1)
    }

    func deep(_ x: HelmContext) -> Double {
        let extra: Double = switch helm {
        case .deep0: 0
        case .deep5: 5
        case .deep10: 10
        case .deep15: 15
        default: 0
        }
        let groove = Autohelm.grooveAngle(.downwind, tws: x.tws, boatClass: x.boat)
        let aimAngle = x.planing ? groove + deg2rad(extra) : groove - deg2rad(10)
        let aim = compass(wind: x.windDir, sailingAngle: aimAngle, boom: x.boom)
        return holdLaw(heading: x.heading, aim: aim)
    }
}

struct WindBook: Sendable {
    struct Series: Sendable { var direction: [Double]; var scale: [Double] }
    var series: [Int: Series]
    var offset: [Int: Int]

    static func load() throws -> WindBook {
        var book = WindBook(series: [:], offset: [:])
        for seed in 1...6 {
            book.series[seed] = try record(seed)
            var mix = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
            mix = mix &* 6364136223846793005 &+ 1
            let room = max((150 - 60) * Race.tickRate, 1)
            book.offset[seed] = Int(mix % UInt64(room))
            fputs("wind seed \(seed): \(book.series[seed]?.scale.count ?? 0) samples, offset \(book.offset[seed] ?? 0)\n", stderr)
        }
        return book
    }

    func sample(knots wanted: Double, seed: Int?, tick: Int) -> (direction: Double, speed: Double) {
        let speed = metresPerSecond(knots: wanted)
        guard let seed, let series = series[seed], let start = offset[seed], !series.scale.isEmpty else {
            return (0, speed)
        }
        let i = (start + tick) % series.scale.count
        return (series.direction[i], series.scale[i] * speed)
    }

    static func record(_ seed: Int) throws -> Series {
        let conditions = try ConditionsFile.bundled(id: "gusty-offshore", version: 7)
        let venue = try VenueFile.bundled(id: "dev-venue", version: 7)
        let setup = try RaceSetup(raceSeed: RaceSeed(UInt64(seed)), seats: [.human, .human], laps: 1,
                                  startSequenceTicks: 1, venue: venue.ref, conditions: conditions.ref)
        let race = try Race(setup: setup, files: try RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: UInt64(seed))))
        race.step()
        let point = race.boats[0].position
        var snap = race.exportSnapshot()
        for i in snap.seats.indices {
            snap.seats[i].boat.speed = 0
            snap.seats[i].boat.rudder = 0
            snap.seats[i].boat.desiredRudder = 0
            snap.seats[i].heldInput = .neutral
        }
        try race.importSnapshot(snap)
        let n = 150 * Race.tickRate
        var direction: [Double] = []
        var speed: [Double] = []
        direction.reserveCapacity(n)
        speed.reserveCapacity(n)
        for _ in 0..<n {
            race.step()
            let wind = race.groundWind(at: point)
            direction.append(wind.direction)
            speed.append(wind.speed)
        }
        let meanSpeed = speed.reduce(0, +) / Double(n)
        var east = 0.0, north = 0.0
        for angle in direction {
            east += sin(angle)
            north += cos(angle)
        }
        let mean = atan2(east / Double(n), north / Double(n))
        return Series(direction: direction.map { wrapAngle($0 - mean) },
                      scale: speed.map { meanSpeed > 1e-6 ? $0 / meanSpeed : 1 })
    }
}

struct Options {
    var stage = 0
    var jobs = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    var help = false
    var report = false
    var caseName: String?
    var maneuver = "tack"
    var knots = 10.0
    var entry = 1.0
    var cut: Int?

    static let usage = """
    regatta-botsuite tack-sweep [--stage 0|1|2|3|4|5] [--jobs n] [--report]
        [--case <helm> --maneuver tack|gybe|run --knots n --entry f]
    """

    init(_ arguments: [String]) throws {
        var args = arguments
        func number(_ flag: String) throws -> Double {
            guard !args.isEmpty, let value = Double(args.removeFirst()) else { throw SweepError.message("\(flag) needs a number") }
            return value
        }
        while !args.isEmpty {
            let flag = args.removeFirst()
            switch flag {
            case "--stage": stage = Int(try number(flag))
            case "--jobs": jobs = max(1, Int(try number(flag)))
            case "--help", "-h": help = true
            case "--report": report = true
            case "--case":
                guard !args.isEmpty else { throw SweepError.message("--case needs a helm") }
                caseName = args.removeFirst()
            case "--maneuver":
                guard !args.isEmpty else { throw SweepError.message("--maneuver needs a name") }
                maneuver = args.removeFirst()
            case "--knots": knots = try number(flag)
            case "--entry": entry = try number(flag)
            case "--cut": cut = Int(try number(flag))
            default: throw SweepError.message("unknown option \(flag)")
            }
        }
    }
}

enum SweepError: Error, CustomStringConvertible {
    case baseline
    case empty
    case message(String)
    var description: String {
        switch self {
        case .baseline: "baseline did not reproduce #454 within 0.1 L"
        case .empty: "no candidates"
        case .message(let text): text
        }
    }
}

func compass(wind: Double, sailingAngle: Double, boom: BoomSide) -> Double {
    let relative = boom == .port ? sailingAngle : -sailingAngle
    return wrapAngle(wind - relative)
}

func headingRemaining(from heading: Double, to aim: Double, turnSign: Double) -> Double {
    let delta = wrapAngle(aim - heading)
    return turnSign >= 0 ? delta : -delta
}

func quantise(_ raw: Double) -> Double {
    let held = BoatInput(rudder: raw).rudderValue
    return abs(held) <= Autohelm.deadBand ? 0 : held
}

func holdLaw(heading: Double, aim: Double) -> Double {
    quantise((0.1 * rad2deg(wrapAngle(aim - heading))).clamped(to: -1...1))
}

func levels(_ lo: Double, _ hi: Double, _ n: Int) -> [Double] {
    guard n > 1 else { return [lo] }
    return (0..<n).map { lo + (hi - lo) * Double($0) / Double(n - 1) }
}

func enumerate(_ axes: [[Double]], body: ([Double]) -> Void) {
    guard !axes.isEmpty else { return }
    var index = Array(repeating: 0, count: axes.count)
    while true {
        body(axes.indices.map { axes[$0][index[$0]] })
        var digit = 0
        while digit < axes.count {
            index[digit] += 1
            if index[digit] < axes[digit].count { break }
            index[digit] = 0
            digit += 1
        }
        if digit == axes.count { return }
    }
}

func boatClass(_ params: SweepParams) throws -> BoatClass {
    try tunedFile(params).content
}

func tunedFile(_ params: SweepParams) throws -> BoatClassFile {
    guard let data = try BoatClassFile.bundledData(id: "skiff", version: 7) else {
        throw SweepError.message("skiff@7 is not bundled")
    }
    return try TunedCopy.make(BoatClass.self, base: data, values: params.pointers(), tune: 1).file
}

func shell(_ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func save(_ rows: [TackSweep.Row], name: String) throws {
    let data = try JSONEncoder().encode(rows)
    try data.write(to: TackSweep.outDir.appendingPathComponent(name))
    if name.hasSuffix("best.json") || name.hasPrefix("stage") || name == "subsets.json" {
        try data.write(to: TackSweep.resultsDir.appendingPathComponent(name))
    }
}

func loadRows(_ name: String) throws -> [TackSweep.Row] {
    let data = try Data(contentsOf: TackSweep.outDir.appendingPathComponent(name))
    return try JSONDecoder().decode([TackSweep.Row].self, from: data)
}

func inParallel<Item: Sendable, Output: Sendable>(_ items: [Item], jobs: Int,
                                                  _ transform: @Sendable (Item) throws -> Output) throws -> [Output] {
    let workers = min(max(jobs, 1), max(items.count, 1))
    guard workers > 1, items.count > 1 else { return try items.map(transform) }
    let slots = SweepSlots<Output>(count: items.count)
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        while let index = slots.claim() {
            slots.store(Swift.Result { try transform(items[index]) }, at: index)
        }
    }
    return try slots.results()
}

private final class SweepSlots<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var failed = false
    private var outcomes: [Result<Value, any Error>?]
    init(count: Int) { outcomes = Array(repeating: nil, count: count) }
    func claim() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, next < outcomes.count else { return nil }
        defer { next += 1 }
        return next
    }
    func store(_ outcome: Result<Value, any Error>, at index: Int) {
        lock.lock()
        outcomes[index] = outcome
        if case .failure = outcome { failed = true }
        lock.unlock()
    }
    func results() throws -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        var values: [Value] = []
        for outcome in outcomes {
            guard let outcome else { break }
            values.append(try outcome.get())
        }
        return values
    }
}

extension Array where Element: BinaryFloatingPoint {
    var mean: Element { isEmpty ? 0 : reduce(0, +) / Element(count) }
}
