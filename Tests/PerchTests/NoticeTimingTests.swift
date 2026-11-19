import Testing
@testable import Perch

@Suite struct NoticeTimingTests {
    @Test(arguments: [("Perched", 1.0), ("Unperched", 1.0), ("Perch ignores", 1.0),
                      ("Unperched: allow Screen Recording", 2.5), ("Perch ignores Visual Studio Code", 2.5)])
    func longerNoticesStayLongerToRead(text: String, seconds: Double) {
        #expect(PinFeedbackHUD.onScreenSeconds(for: text) == seconds)
    }
}
