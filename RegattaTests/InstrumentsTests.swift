import CoreGraphics
import Foundation
import Testing
import RegattaCore
@testable import Regatta

/// #457 acceptance: the race HUD's speed and apparent wind instruments. Their words (speed one decimal, the apparent
/// wind's angle in whole degrees with its side word, its speed in whole knots), the display smoothing, the reading from
/// your boat's `apparentWind` and heading, when they show, VoiceOver's values, the bottom row's fit, and their colour.
@MainActor @Suite struct InstrumentsTests {
    private static func hud(status: BoatStatus = .racing, isGhost: Bool = false,
                            shown: InstrumentReading = InstrumentReading()) -> HUDState {
        var hud = HUDState()
        hud.status = status
        hud.isGhost = isGhost
        hud.instruments = shown
        hud.shownInstruments = shown
        return hud
    }

    @Test func speedIsOneDecimalInKnots() {
        #expect(HUDModel.speedText(knots: knots(metresPerSecond: 3.29)) == "6.4")
        #expect(HUDModel.speedText(knots: 0) == "0.0")
        #expect(HUDModel.speedText(knots: 12.04) == "12.0")
        #expect(HUDModel.speedText(knots: 9.96) == "10.0")
        // Pushed backwards: 0.0, never "-0.0" or a negative speed.
        #expect(HUDModel.speedText(knots: -0.04) == "0.0")
        #expect(HUDModel.speedText(knots: -1.2) == "0.0")
    }

    @Test func apparentWindIsWholeDegreesWithItsSideAndWholeKnots() {
        #expect(HUDModel.apparentAngleText(angle: deg2rad(38)) == "38° starboard")
        #expect(HUDModel.apparentAngleText(angle: deg2rad(-38)) == "38° port")
        #expect(HUDModel.apparentAngleText(angle: deg2rad(-37.6)) == "38° port")
        #expect(HUDModel.apparentAngleText(angle: deg2rad(142.4)) == "142° starboard")
        // Dead ahead and dead astern have no side; rounding to them drops it too.
        #expect(HUDModel.apparentAngleText(angle: 0) == "0°")
        #expect(HUDModel.apparentAngleText(angle: deg2rad(0.4)) == "0°")
        #expect(HUDModel.apparentAngleText(angle: .pi) == "180°")
        #expect(HUDModel.apparentAngleText(angle: -.pi) == "180°")
        #expect(HUDModel.apparentAngleText(angle: deg2rad(-179.6)) == "180°")
        // Wrapped: 322° off the bow is 38° over port.
        #expect(HUDModel.apparentAngleText(angle: deg2rad(322)) == "38° port")
        #expect(HUDModel.knotsText(20.6) == "21 kn")
        #expect(HUDModel.knotsText(0.4) == "0 kn")
        #expect(HUDModel.knotsText(-1) == "0 kn")

        let model = HUDModel(Self.hud(shown: InstrumentReading(speedKnots: 6.43, apparentAngle: deg2rad(-38.2),
                                                               apparentKnots: 20.7)))
        #expect(model.speedText == "6.4")
        #expect(model.apparentAngleText == "38° port")
        #expect(model.apparentSpeedText == "21 kn")
    }

    /// The figures show what the smoothing gives (`shownInstruments`), not the raw reading.
    @Test func modelReadsTheSmoothedReading() {
        var hud = Self.hud(shown: InstrumentReading(speedKnots: 5, apparentAngle: deg2rad(40), apparentKnots: 12))
        hud.instruments = InstrumentReading(speedKnots: 7, apparentAngle: deg2rad(-40), apparentKnots: 14)
        let model = HUDModel(hud)
        #expect(model.speedText == "5.0" && model.apparentAngleText == "40° starboard" && model.apparentSpeedText == "12 kn")
    }

    @Test func voiceOverValues() {
        let model = HUDModel(Self.hud(shown: InstrumentReading(speedKnots: 6.4, apparentAngle: deg2rad(-38),
                                                               apparentKnots: 21)))
        #expect(model.speedAccessibilityValue == "6.4 knots")
        #expect(model.apparentAccessibilityValue == "38 degrees port, 21 knots")
        let ahead = HUDModel(Self.hud(shown: InstrumentReading(speedKnots: 0, apparentAngle: 0, apparentKnots: 1)))
        #expect(ahead.speedAccessibilityValue == "0.0 knots")
        #expect(ahead.apparentAccessibilityValue == "0 degrees, 1 knot")
        let one = HUDModel(Self.hud(shown: InstrumentReading(apparentAngle: deg2rad(1), apparentKnots: 9)))
        #expect(one.apparentAccessibilityValue == "1 degree starboard, 9 knots")
    }

    /// A step in speed settles within about a second at the HUD's 15 Hz and is all but gone by two; one refresh
    /// moves part of the way, so the tenths don't flicker.
    @Test func smoothingSettlesWithinASecond() {
        var smoother = InstrumentSmoother()
        let start = InstrumentReading(speedKnots: 6, apparentAngle: deg2rad(30), apparentKnots: 14)
        #expect(smoother.step(start, at: 10) == start, "the first reading shows as it is")
        let dipped = InstrumentReading(speedKnots: 4, apparentAngle: deg2rad(40), apparentKnots: 12)
        let dt = 1.0 / 15
        let first = smoother.step(dipped, at: 10 + dt)
        #expect(first.speedKnots < 6 && first.speedKnots > 5, "one refresh moves part of the way: \(first.speedKnots)")
        var shown = first
        for i in 2...15 { shown = smoother.step(dipped, at: 10 + Double(i) * dt) }
        #expect(abs(shown.speedKnots - 4) < 0.1, "within 5% after 1 s: \(shown.speedKnots)")
        #expect(abs(shown.apparentKnots - 12) < 0.1)
        #expect(abs(rad2deg(shown.apparentAngle) - 40) < 0.5)
        for i in 16...30 { shown = smoother.step(dipped, at: 10 + Double(i) * dt) }
        #expect(abs(shown.speedKnots - 4) < 0.01, "no lag over 2 s: \(shown.speedKnots)")
    }

    /// Head to wind and dead downwind the angle is smoothed the short way round, never through the beam.
    @Test func smoothingWrapsTheAngleTheShortWay() {
        var smoother = InstrumentSmoother()
        _ = smoother.step(InstrumentReading(apparentAngle: deg2rad(175)), at: 0)
        let next = smoother.step(InstrumentReading(apparentAngle: deg2rad(-175)), at: 1.0 / 15)
        #expect(abs(rad2deg(next.apparentAngle)) > 175, "through 180°, not the bow: \(rad2deg(next.apparentAngle))")
        _ = smoother.step(InstrumentReading(apparentAngle: deg2rad(-5)), at: 5)
        let tack = smoother.step(InstrumentReading(apparentAngle: deg2rad(5)), at: 5 + 1.0 / 15)
        #expect(abs(rad2deg(tack.apparentAngle)) < 5, "through the bow: \(rad2deg(tack.apparentAngle))")
    }

    /// Nothing moves while race time stands still (paused); a jump in race time (a restart) shows the raw reading.
    @Test func smoothingHoldsWhilePausedAndSnapsOnAJump() {
        var smoother = InstrumentSmoother()
        let a = InstrumentReading(speedKnots: 6, apparentAngle: deg2rad(30), apparentKnots: 14)
        let b = InstrumentReading(speedKnots: 2, apparentAngle: deg2rad(-90), apparentKnots: 8)
        _ = smoother.step(a, at: 20)
        #expect(smoother.step(b, at: 20) == a, "paused")
        #expect(smoother.step(b, at: -60) == b, "restarted")
        _ = smoother.step(a, at: -59.9)
        #expect(smoother.step(b, at: -50) == b, "a long gap")
    }

    /// The reading is your boat's: her speed, and her `apparentWind` off her bow, positive over starboard.
    @Test func readsYourBoatsApparentWindOffTheBow() {
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let frame = driver.currentFrame
        let me = driver.myBoatIndex
        func hud(heading: Double, apparentFrom: Double, status: BoatStatus = .racing) -> HUDState {
            var boats = frame.boats
            boats[me].heading = deg2rad(heading)
            boats[me].speed = 3.29
            boats[me].status = status
            boats[me].apparentWind = Wind(direction: deg2rad(apparentFrom), speed: 21 / knots(metresPerSecond: 1))
            let moved = TickFrame(tick: frame.tick, boats: boats, standings: frame.standings, wind: frame.wind,
                                  isOver: frame.isOver)
            return HUDState(world: RenderWorld(course: driver.course, boatClass: driver.boatClass, myBoatIndex: me,
                                               previous: moved, current: moved, alpha: 1))
        }
        let starboard = hud(heading: 10, apparentFrom: 48)
        #expect(abs(rad2deg(starboard.instruments.apparentAngle) - 38) < 1e-9)
        #expect(abs(starboard.instruments.apparentKnots - 21) < 1e-9)
        #expect(abs(starboard.instruments.speedKnots - knots(metresPerSecond: 3.29)) < 1e-9)
        #expect(starboard.shownInstruments == starboard.instruments, "raw until the session smooths it")
        #expect(HUDModel(starboard).apparentAngleText == "38° starboard")
        #expect(HUDModel(hud(heading: 10, apparentFrom: 332)).apparentAngleText == "38° port")
        // Across north: heading 350°, wind from 28° is 38° over starboard; heading 20°, wind from 342°, over port.
        #expect(HUDModel(hud(heading: 350, apparentFrom: 28)).apparentAngleText == "38° starboard")
        #expect(HUDModel(hud(heading: 20, apparentFrom: 342)).apparentAngleText == "38° port")
        // Dead downwind both ways round.
        #expect(HUDModel(hud(heading: 0, apparentFrom: 180)).apparentAngleText == "180°")
        #expect(HUDModel(hud(heading: 90, apparentFrom: 268)).apparentAngleText == "178° starboard")
        #expect(HUDModel(hud(heading: 90, apparentFrom: 272)).apparentAngleText == "178° port")
        // Done: a finished boat is a ghost, and the instruments hide.
        let finished = hud(heading: 0, apparentFrom: 40, status: .finished)
        #expect(finished.isGhost && !HUDModel(finished).showsInstruments)
    }

    /// Shown from the start of the race scene (the approach too) while racing, hidden once you're done.
    @Test func shownPrestartAndRacingHiddenWhenDone() {
        #expect(HUDModel(Self.hud(status: .prestart)).showsInstruments)
        #expect(HUDModel(Self.hud(status: .ocs)).showsInstruments)
        #expect(HUDModel(Self.hud(status: .racing)).showsInstruments)
        #expect(!HUDModel(Self.hud(status: .finished)).showsInstruments)
        #expect(!HUDModel(Self.hud(status: .dsq)).showsInstruments)
        // Still OCS or unstarted when the race closes: a ghost.
        #expect(!HUDModel(Self.hud(status: .ocs, isGhost: true)).showsInstruments)
        #expect(!HUDModel(Self.hud(status: .prestart, isGhost: true)).showsInstruments)

        // A practice race opens in its sequence with them shown.
        let driver = PracticeDriver(config: RaceDriverTests.config)
        #expect(HUDModel(HUDState(world: driver.renderWorld)).showsInstruments)
    }

    /// Speed and the apparent wind sit side by side as a pair, centred on the row with the 8 pt gap between them
    /// (#460: no Tack/Gybe between them), and fit on the narrowest phone (320 pt), an SE's, an iPhone 17's, a Pro
    /// Max's and the iPad letterboxes; the row's height is the controls' (the edge arrow's clearance, `rowHeight`,
    /// is unchanged).
    @Test func bottomRowFitsAtEveryRaceWidth() {
        func letterbox(_ screen: CGSize, landscape: Bool) -> CGFloat {
            let window = landscape ? CGSize(width: screen.height, height: screen.width) : screen
            return RaceViewportPolicy.shipping.layout(window: window, screen: window).raceRect.width
        }
        let iPads = [CGSize(width: 744, height: 1133), CGSize(width: 820, height: 1180), CGSize(width: 1032, height: 1376)]
            .flatMap { [letterbox($0, landscape: true), letterbox($0, landscape: false)] }
        let widestAngle = [deg2rad(178), deg2rad(-178), deg2rad(38)].map(RaceControls.apparentLineWidth).max()!
        let widestKnots = HUDLayout.width(of: HUDModel.knotsText(48), size: RaceControls.angleSize)
        let widestSpeed = HUDLayout.width(of: HUDModel.speedText(knots: 29.9), size: RaceControls.speedSize,
                                          weight: .heavy)
        #expect(RaceControls.spacing == 8)
        for width in [320, 375, 402, 430] + iPads {
            let instrument = RaceControls.instrumentWidth(rowWidth: width)
            let row = 2 * RaceControls.edge + RaceControls.spacing + 2 * instrument
            #expect(row <= width + 0.001, "at \(width) pt the row needs \(row) pt")
            #expect(instrument == RaceControls.instrumentMaxWidth, "at \(width) pt an instrument gets \(instrument) pt")
            // The pair is centred: as far from the leading edge as from the trailing one, inside the margins.
            let pair = RaceControls.instrumentPair(rowWidth: width)
            #expect(abs(pair.lowerBound - (width - pair.upperBound)) < 0.001, "at \(width) pt the pair sits at \(pair)")
            #expect(abs((pair.upperBound - pair.lowerBound) - (2 * instrument + RaceControls.spacing)) < 0.001)
            #expect(pair.lowerBound >= RaceControls.edge - 0.001)
            // VoiceOver's Ease element (bottom leading, 44 pt under a UI test at 7 pt in) stays clear of it.
            #expect(pair.lowerBound >= 7 + 44, "at \(width) pt the pair starts at \(pair.lowerBound)")
            let inside = instrument - 2 * RaceControls.instrumentInset
            #expect(widestAngle * RaceControls.minimumScale <= inside, "at \(width) pt \(widestAngle) in \(inside)")
            #expect(widestKnots <= inside && widestSpeed <= inside, "at \(width) pt")
        }
        // From an SE up the angle's words fit unshrunk.
        let inside = RaceControls.instrumentWidth(rowWidth: 375) - 2 * RaceControls.instrumentInset
        #expect(widestAngle <= inside, "\(widestAngle) in \(inside)")
        #expect(RaceControls.rowHeight == RaceControls.controlHeight + RaceControls.bottomPadding)
        #expect(RaceControls.rowHeight == 72)
    }

    /// No target, no band, no tone: the instruments draw white on translucent black only, never the reserved cue
    /// colours (orange is the active leg's, #22, G7) and nothing by red or green (#5, #15). One exception (#492): the
    /// speed tile on the plane, the planing yellow under dark figures, named once.
    @Test func instrumentsDrawWhiteOnly() throws {
        let url = RaceDriverTests.repoRoot.appending(path: "Regatta/UI/RaceControls.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "struct InstrumentRow"))
        let end = try #require(source.range(of: "/// VoiceOver's Ease (#453)"))
        let all = String(source[start.lowerBound..<end.lowerBound])
        #expect(all.components(separatedBy: "CuePalette.planingYellow").count == 2, "the planing yellow, once")
        #expect(all.contains(".foregroundStyle(darkFigures ? .black : .white)"))
        let instruments = all.replacingOccurrences(of: "CuePalette.planingYellow", with: "")
        for colour in ["CuePalette", "Palette.", "orange", ".red", ".green", ".yellow", ".tint", "Color("] {
            #expect(!instruments.contains(colour), "the instruments use \(colour)")
        }
        #expect(!instruments.contains(".foregroundStyle(.white)"), "one face, one figure colour")
        #expect(instruments.contains(".allowsHitTesting(false)"), "never a tap target")
    }

    /// #492: the speed tile's planing yellow follows your boat's flag over its seconds of race time: all the way after
    /// that long on or off, never more than `1.5 * dt / seconds` a step, steady while the flag flickers, and as she
    /// is on the first reading, after a jump in race time and when time runs backwards. With no race time passing (a
    /// pause, a frozen fixture) it holds.
    @Test func planingTileComesAndGoesWithTheFlag() {
        let seconds = 0.4, dt = 1.0 / 15
        var tile = PlaningTile()
        #expect(tile.step(isPlaning: false, at: 10, seconds: seconds) == 0)
        var time = 10.0, last = 0.0
        func run(_ isPlaning: (Int) -> Bool, steps: Int, _ check: (Double) -> Void = { _ in }) {
            for step in 0..<steps {
                time += dt
                let level = tile.step(isPlaning: isPlaning(step), at: time, seconds: seconds)
                #expect((0...1).contains(level) && abs(level - last) <= 1.5 * dt / seconds + 1e-12, "\(last) to \(level)")
                last = level
                check(level)
            }
        }
        run({ _ in true }, steps: 1)
        #expect(last > 0 && last < 0.5, "a step in she is on her way, not there: \(last)")
        run({ _ in true }, steps: 6)
        #expect(last == 1)
        // The flag flickering every step: within a step's worth of where it was.
        run({ $0.isMultiple(of: 2) }, steps: 30) { #expect($0 > 1 - 1.5 * dt / seconds - 1e-12) }
        run({ _ in false }, steps: 7)
        #expect(last == 0)
        // Paused: the same race time again moves nothing.
        run({ _ in true }, steps: 2)
        let held = last
        #expect(held > 0 && held < 1)
        #expect(tile.step(isPlaning: true, at: time, seconds: seconds) == held)
        #expect(tile.step(isPlaning: false, at: time, seconds: seconds) == held)
        // A restart (time back) and a jump ahead: as she is.
        #expect(tile.step(isPlaning: false, at: time - 5, seconds: seconds) == 0)
        #expect(tile.step(isPlaning: true, at: time + 60, seconds: seconds) == 1)
        // No seconds: with the flag.
        var snap = PlaningTile()
        #expect(snap.step(isPlaning: false, at: 0, seconds: 0) == 0 && snap.step(isPlaning: true, at: dt, seconds: 0) == 1)
    }

    /// #492: the tile's state in the HUD. The world's frame gives your boat's flag and the tile all or nothing (a
    /// frozen fixture's HUD, which nothing eases); the figures go dark from half yellow; VoiceOver's value gains
    /// "planing" with the flag, whatever the tile's strength.
    @Test func speedTileIsYellowOnThePlane() throws {
        let off = Self.hud(shown: InstrumentReading(speedKnots: 6.4, apparentAngle: 0.6, apparentKnots: 12))
        #expect(off.planingYellow == 0 && !off.isPlaning)
        #expect(HUDModel(off).speedTileYellow == 0 && !HUDModel(off).speedTileHasDarkFigures)
        #expect(HUDModel(off).speedAccessibilityValue == "6.4 knots")
        var on = Self.hud(shown: InstrumentReading(speedKnots: 16, apparentAngle: 0.6, apparentKnots: 12))
        on.isPlaning = true
        on.planingYellow = 0.85
        #expect(HUDModel(on).speedTileYellow == 0.85 && HUDModel(on).speedTileHasDarkFigures)
        #expect(HUDModel(on).speedAccessibilityValue == "16.0 knots, planing")
        for (yellow, dark) in [(0.0, false), (0.2, false), (0.49, false), (0.5, true), (0.85, true), (1, true), (1.4, true), (-1, false)] {
            on.planingYellow = yellow
            #expect(HUDModel(on).speedTileHasDarkFigures == dark, "\(yellow)")
            #expect((0...1).contains(HUDModel(on).speedTileYellow))
        }
        // The tile switched off in the tuning panel: no yellow, the word stays.
        on.planingYellow = 0
        #expect(HUDModel(on).speedAccessibilityValue == "16.0 knots, planing")

        // From the world: your boat's flag, and the tile as she is.
        let driver = PracticeDriver(config: RaceDriverTests.config)
        let frame = driver.currentFrame
        let me = driver.myBoatIndex
        for planing in [false, true] {
            var boats = frame.boats
            boats[me].isPlaning = planing
            let moved = TickFrame(tick: frame.tick, boats: boats, standings: frame.standings, wind: frame.wind,
                                  isOver: frame.isOver)
            let hud = HUDState(world: RenderWorld(course: driver.course, boatClass: driver.boatClass, myBoatIndex: me,
                                                  previous: moved, current: moved, alpha: 1))
            #expect(hud.isPlaning == planing && hud.planingYellow == (planing ? 1 : 0))
        }
        // The yellow is the planing token, at the style's strength: clear of the penalty arc's amber by the hue rule.
        #expect(OKLCH.hueDistance(CuePalette.planingYellow.oklch.h, CuePalette.orange.oklch.h) >= 20)
        #expect(BoatStyle.standard.planingTileAlpha == 0.85 && BoatStyle.standard.planingTileSeconds == 0.4)
        #expect(BoatStyle.standard.planeMarginFullSpeedShare == 0.85, "full length in ordinary planing (owner, 2026-10-12)")
    }

    /// #492: the plane the race seats the fleet on is not the cue's. `Race.init` rows every boat up reaching at speed,
    /// so the rule has them planing from the first tick; for `PlaningCue.seatedSeconds` from the seating the frame
    /// says so (`TickFrame.isJustSeated`) and your tile stays as it was, VoiceOver's word with it. After that a boat
    /// still on the plane shows it. The race's own flags are untouched: the frames carry them as the race has them.
    /// On the start row's rules, fleet-rules@7 (#477): the default's opening seats the fleet eased, off the plane.
    @Test func seatedFleetShowsNoPlane() throws {
        var config = RaceDriverTests.config
        config.files.rulesConfiguration = try RulesConfigFile.bundled(id: "fleet-rules", version: 7).ref
        let driver = PracticeDriver(config: config)
        let me = driver.myBoatIndex
        func hud(_ frame: TickFrame) -> HUDState {
            HUDState(world: RenderWorld(course: driver.course, boatClass: driver.boatClass, myBoatIndex: me,
                                        previous: frame, current: frame, alpha: 1))
        }
        let seated = driver.currentFrame
        #expect(seated.seatedTick == seated.tick && seated.tick == -60 * Race.tickRate && seated.isJustSeated)
        var flagged = 0, frames = [seated]
        while frames.count <= Int(PlaningCue.seatedSeconds * Double(Race.tickRate)) + 30 {
            frames += driver.tick(1.0 / Double(Race.tickRate))
        }
        for frame in frames.dropFirst() {
            let since = Double(frame.tick - seated.tick) / Double(Race.tickRate)
            #expect(frame.seatedTick == seated.tick && frame.isJustSeated == (since < PlaningCue.seatedSeconds), "\(since) s")
            #expect(frame.extrapolatedBackOneTick().seatedTick == seated.tick)
            if frame.isJustSeated {
                flagged += frame.boats.count { $0.isPlaning }
                #expect(!hud(frame).isPlaning && hud(frame).planingYellow == 0, "\(since) s after the seating")
                #expect(!HUDModel(hud(frame)).speedAccessibilityValue.contains("planing"))
            } else {
                #expect(hud(frame).isPlaning == frame.boats[me].isPlaning)
            }
        }
        #expect(flagged > 0, "the seated fleet no longer carries the flag: the cue has nothing to leave out")
        // A boat's flag a second in, and the same boat once the seating is behind her.
        var boats = seated.boats
        boats[me].isPlaning = true
        for (ticks, shows) in [(0, false), (30, false), (89, false), (90, true), (600, true)] {
            let frame = TickFrame(tick: seated.tick + ticks, boats: boats, standings: seated.standings, wind: seated.wind,
                                  isOver: false, seatedTick: seated.tick)
            #expect(hud(frame).isPlaning == shows && frame.isJustSeated == !shows, "\(ticks) ticks")
        }
        // A frame that is no race's (the help legend's) is never just seated.
        #expect(!TickFrame(tick: seated.tick, boats: boats, standings: seated.standings, wind: seated.wind, isOver: false).isJustSeated)
        #expect(PlaningCue.shows(boats[me], justSeated: false) && !PlaningCue.shows(boats[me], justSeated: true))
        #expect(!PlaningCue.shows(seated.boats[me], justSeated: false))
    }

    /// #460: the Tack/Gybe button, the roll ring and their plumbing are gone from the app, tests and UI tests. The
    /// driver's tap stays (`RaceDriver.tap(.tackGybe)`: old logs, the sim and the online protocol carry it).
    @Test func noTackButtonOrRollRingRemains() throws {
        let gone = ["RollRing", "TackHold", "pressTack", "releaseTack", "rollRing", "HoldButton", "race-" + "tack",
                    "tackWidth", "TapTurn", "FlogTimer", "FlareTimer", "isFlogging", "wakeFlare", "RollCue",
                    "controlReleases"]
        let root = RaceDriverTests.repoRoot
        var scanned = 0
        for folder in ["Regatta", "RegattaTests", "RegattaUITests"] {
            let files = try #require(FileManager.default.enumerator(at: root.appending(path: folder),
                                                                    includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                // This test names them.
                guard url.lastPathComponent != "InstrumentsTests.swift" else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                for word in gone { #expect(!source.contains(word), "\(url.lastPathComponent) has \(word)") }
            }
        }
        #expect(scanned > 100, "\(scanned) files scanned")
        let controls = try String(contentsOf: root.appending(path: "Regatta/UI/RaceControls.swift"), encoding: .utf8)
        #expect(controls.contains("race-ease") && controls.contains("race-speed") && controls.contains("race-apparent-wind"))
    }
}
