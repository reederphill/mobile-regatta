#if canImport(Network)
@testable import RegattaServices
import Testing

/// `PathConnectivityService` passes on changes, not the path monitor's repeats (#314). Driven through `update(_:)`,
/// as an `NWPath` can't be built; macOS only, like the service.
@Suite struct PathConnectivityServiceTests {
    @Test func repeatsAreDroppedAndChangesPassOn() async {
        var service: PathConnectivityService? = PathConnectivityService(monitoring: false)
        var updates = service!.statusUpdates().makeAsyncIterator()
        #expect(await updates.next() == .online, "the stream opens with the status now")

        for status: ConnectivityStatus in [.online, .offline, .offline, .offline, .online, .online] { service?.update(status) }
        let late = service!.statusUpdates()
        // Dropping the service finishes its streams, so what they hold is all they will ever give.
        service = nil
        var rest: [ConnectivityStatus] = []
        while let status = await updates.next() { rest.append(status) }
        #expect(rest == [.offline, .online])
        var lateUpdates: [ConnectivityStatus] = []
        for await status in late { lateUpdates.append(status) }
        #expect(lateUpdates == [.online], "a stream opened later starts at the status then")
    }
}
#endif
