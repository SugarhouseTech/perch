import CoreGraphics
import Foundation
import Testing
@testable import Perch

@Suite struct FocusedWindowMatchingTests {
    private let first = CGRect(x: 20, y: 40, width: 500, height: 400)
    private let second = CGRect(x: 30, y: 70, width: 500, height: 400)

    private func window(_ id: CGWindowID, title: String = "zsh", bounds: CGRect,
                        pid: pid_t = 20, layer: Int = 0) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowName as String: title,
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer
        ]
    }

    private func match(_ list: [[String: Any]], id: CGWindowID? = nil,
                       title: String? = "zsh", bounds: CGRect? = nil) -> CGWindowID? {
        WindowDetector.matchFocusedWindow(id: id, title: title, bounds: bounds,
                                          ownerPID: 20, ownerName: "Terminal", in: list)?.windowID
    }

    @Test func exactWindowIDWinsOverTitleAndBounds() {
        let list = [window(1, bounds: first), window(2, title: "Shell", bounds: second)]
        #expect(match(list, id: 2, bounds: first) == 2)
    }

    @Test func knownIDNeverFallsThroughToAnUnrelatedWindow() {
        let list = [window(1, bounds: first), window(2, bounds: first, layer: 3), window(3, bounds: first, pid: 99)]
        for id: CGWindowID in [2, 3, 4] {
            #expect(match(list, id: id, bounds: first) == nil)
        }
    }

    @Test func boundsDisambiguateDuplicateTitles() {
        let list = [window(1, bounds: first), window(2, bounds: second)]
        #expect(match(list, bounds: second) == 2)
        #expect(match(list) == nil)
    }

    @Test func conflictingEvidenceAndUnmatchedWindowsAreNotGuessed() {
        let list = [window(1, bounds: first), window(2, title: "Shell", bounds: second)]
        #expect(match(list, bounds: second) == nil)
        #expect(match([list[0]], bounds: second) == nil)
        #expect(match([list[0]], title: nil) == nil)
    }

    @Test func usesUniqueBoundsOrTitleWhenOtherEvidenceIsMissing() {
        #expect(match([window(1, title: "", bounds: first)], bounds: first) == 1)
        #expect(match([window(1, bounds: first), window(2, title: "Shell", bounds: second)]) == 1)
    }
}
