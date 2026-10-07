import Testing
@testable import Regatta

/// Settings' notice alert (#110, #314): the deletion notice waits for the confirmation dialog to go.
@MainActor @Suite struct SettingsNoticeTests {
    @Test func aNoticeWaitsForTheDialogToGo() {
        var notice = SettingsNotice()
        notice.dialogIsUp = true
        notice.arrive("Deleting online data arrives with online accounts.")
        #expect(notice.shown == nil, "the alert is raised while the dialog is still up")
        notice.dialogIsUp = false
        #expect(notice.shown == "Deleting online data arrives with online accounts.")
        notice.shown = nil
        notice.dialogIsUp = true
        notice.dialogIsUp = false
        #expect(notice.shown == nil, "a notice shows twice")
    }

    @Test func aNoticeWithNoDialogShowsAtOnce() {
        var notice = SettingsNotice()
        notice.arrive("Hints will show again.")
        #expect(notice.shown == "Hints will show again.")
    }
}
