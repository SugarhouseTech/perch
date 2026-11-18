import CoreGraphics
import Testing
@testable import Perch

@Suite struct MenuBarGlyphPathTests {
    /// The shapes are written with each command letter against its first
    /// number ("M4.1"); a reader that wanted them spaced drew nothing at all.
    @Test func readsCommandsWrittenAgainstTheirNumbers() {
        let path = MenuBarGlyph.path("M1 2 L3 4 C5 6 7 8 9 10Z M0,0 L1,1")
        #expect(path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 9, height: 10))
        let tight = MenuBarGlyph.path("M4.12 1.2 L15.5 11.42 Z")
        #expect(tight.boundingBoxOfPath.minX == 4.12)
        #expect(tight.boundingBoxOfPath.maxY == 11.42)
    }
}
