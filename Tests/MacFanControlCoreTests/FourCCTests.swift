import XCTest
@testable import MacFanControlCore

final class FourCCTests: XCTestCase {
    func testStaticMake() {
        XCTAssertEqual(FourCC.make("F0Ac"), 0x46304163)
        XCTAssertEqual(FourCC.make("#KEY"), 0x234B4559)
        XCTAssertEqual(FourCC.make("flt "), 0x666C7420)
    }

    func testRuntimeMake() {
        XCTAssertEqual(FourCC.makeRuntime("F0Ac"), 0x46304163)
        XCTAssertNil(FourCC.makeRuntime("abc"))
        XCTAssertNil(FourCC.makeRuntime("abcde"))
    }

    func testStringRoundTrip() {
        let key = FourCC.make("F0Tg")
        XCTAssertEqual(FourCC.string(key), "F0Tg")
    }

    func testFanKeyBuilder() {
        XCTAssertEqual(FanReader.fanKey(index: 0, suffix: "Ac"), FourCC.make("F0Ac"))
        XCTAssertEqual(FanReader.fanKey(index: 1, suffix: "Tg"), FourCC.make("F1Tg"))
        XCTAssertEqual(FanReader.fanKey(index: 0, suffix: "md"), FourCC.make("F0md"))
    }
}
