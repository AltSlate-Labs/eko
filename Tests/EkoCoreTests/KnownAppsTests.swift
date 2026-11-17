import Testing
@testable import EkoCore

@Test func briefMeetingAppSoundDoesNotNameABrowserCall() {
    // 23 minutes of Chrome holding the mic (weight 3 every 2 s) and one Slack ping.
    #expect(KnownApps.preferredName(from: ["Chrome": 2100, "Slack": 1]) == "Chrome")
}

@Test func meetingAppWinsANearTie() {
    // A Zoom call with a browser tab playing audio alongside.
    #expect(KnownApps.preferredName(from: ["Chrome": 300, "Zoom": 200]) == "Zoom")
}

@Test func mostHeardWinsAmongOtherApps() {
    #expect(KnownApps.preferredName(from: ["Safari": 10, "Chrome": 40]) == "Chrome")
    #expect(KnownApps.preferredName(from: [:]) == nil)
}
