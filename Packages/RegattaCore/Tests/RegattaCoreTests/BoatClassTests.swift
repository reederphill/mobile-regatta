import Foundation
import Testing
@testable import RegattaCore

/// The boat class file's schema 4 (#434, ADR 0004, ADR 0011): `BoatClassTests` is in DataFileTests.swift.
extension BoatClassTests {
    /// `steering.autohelm.holdsWhenCentred` reads a JSON bool or a number, 0 or 1 (a tuned copy writes numbers only);
    /// left out it is true. `handBackDegrees` reads in degrees, 3° when left out. Anything else is refused, and a
    /// schema-3 file never reads them.
    @Test func holdsWhenCentredDecodesBoolOrNumber() throws {
        func holds(_ members: String?) throws -> Bool {
            try AutohelmSettingFixtures.file(members).content.steering.autohelm.holdsWhenCentred
        }
        #expect(try holds(nil))
        #expect(try holds(#""holdsWhenCentred": true"#))
        #expect(try !holds(#""holdsWhenCentred": false"#))
        #expect(try holds(#""holdsWhenCentred": 1"#))
        #expect(try !holds(#""holdsWhenCentred": 0"#))
        #expect(try holds(#""holdsWhenCentred": 1.0"#))
        for bad in [#""holdsWhenCentred": 2"#, #""holdsWhenCentred": 0.5"#, #""holdsWhenCentred": "no""#,
                    #""handBackDegrees": 0"#, #""handBackDegrees": -3"#] {
            #expect(throws: (any Error).self, "\(bad)") { try AutohelmSettingFixtures.file(bad) }
        }

        let handBack = try AutohelmSettingFixtures.file(#""holdsWhenCentred": false, "handBackDegrees": 2"#).content
        #expect(handBack.steering.autohelm.handBack == deg2rad(2))
        #expect(try AutohelmSettingFixtures.file(nil).content.steering.autohelm.handBack == deg2rad(3))

        // The same members in a schema-3 file: not its schema's, so not read.
        let schema3 = try SkiffFixtures.edited([(of: #""grooveWindAverageSeconds": 30"#,
                                                 with: #""grooveWindAverageSeconds": 30, "holdsWhenCentred": false"#)])
        #expect(try BoatClassFile(data: schema3, tune: 1).content.steering.autohelm.holdsWhenCentred)

        // The tuning panel's way: a tuned copy writes the number at its pointer.
        let base = try AutohelmSettingFixtures.data(#""holdsWhenCentred": 1"#)
        let tuned = try TunedCopy.make(BoatClass.self, base: base, values: ["/steering/autohelm/holdsWhenCentred": 0], tune: 2)
        #expect(tuned.isTuned && !tuned.file.content.steering.autohelm.holdsWhenCentred)
    }
}
