import XCTest
@testable import PillCore

/// Proves menu-bar title ink is readable on light Liquid Glass even when the
/// app forces darkAqua (where `NSColor.labelColor` would be white@~0.85).
final class MenuBarTitleInkTests: XCTestCase {

    func testCalmIsNotWhiteOnLight() {
        XCTAssertTrue(
            MenuBarTitleInk.calmIsNotWhiteOnLight(),
            "calm ink must stay dark enough for light menu-bar glass"
        )
        let calm = MenuBarTitleInk.sRGB(for: .calm)
        XCTAssertTrue(MenuBarTitleInk.isReadableOnLightGlass(calm))
        // darkAqua labelColor is near-white luminance — we must be far below that.
        XCTAssertLessThan(calm.relativeLuminance, 0.35, "calm must be near-black, not gray-white")
        XCTAssertLessThan(calm.r, 0.25)
        XCTAssertLessThan(calm.g, 0.25)
        XCTAssertLessThan(calm.b, 0.25)
    }

    func testAllRolesReadableOnLightGlass() {
        for role in MenuBarTitleInk.Role.allCases {
            let ink = MenuBarTitleInk.sRGB(for: role)
            XCTAssertTrue(
                MenuBarTitleInk.isReadableOnLightGlass(ink),
                "\(role.rawValue) luminance \(ink.relativeLuminance) too light for glass bar"
            )
        }
    }

    /// Simulates the darkAqua labelColor failure mode and asserts we reject it.
    func testRejectsNearWhiteLabelColorFailureMode() {
        // Approximate NSColor.labelColor under darkAqua: white @ 0.85.
        let darkAquaLabel = MenuBarTitleInk.SRGB(r: 1, g: 1, b: 1, a: 0.85)
        XCTAssertFalse(
            MenuBarTitleInk.isReadableOnLightGlass(darkAquaLabel),
            "white@0.85 (darkAqua labelColor) must fail the light-glass check"
        )
        // Our calm ink must not equal that failure mode.
        let calm = MenuBarTitleInk.sRGB(for: .calm)
        XCTAssertNotEqual(calm.r, darkAquaLabel.r, accuracy: 0.5)
        XCTAssertLessThan(calm.relativeLuminance, darkAquaLabel.relativeLuminance)
    }

    func testLoadRoleBands() {
        XCTAssertEqual(MenuBarTitleInk.loadRole(percent: nil), .calm)
        XCTAssertEqual(MenuBarTitleInk.loadRole(percent: 50), .calm)
        XCTAssertEqual(MenuBarTitleInk.loadRole(percent: 80), .elevated)
        XCTAssertEqual(MenuBarTitleInk.loadRole(percent: 91.9), .elevated)
        XCTAssertEqual(MenuBarTitleInk.loadRole(percent: 92), .critical)
        XCTAssertEqual(MenuBarTitleInk.loadRole(percent: 100), .critical)
    }

    func testSemanticRolesDistinctFromCalm() {
        let calm = MenuBarTitleInk.sRGB(for: .calm)
        let ask = MenuBarTitleInk.sRGB(for: .ask)
        let collapse = MenuBarTitleInk.sRGB(for: .collapse)
        XCTAssertNotEqual(calm, ask)
        XCTAssertNotEqual(ask, collapse)
        // Ask is warmer (more red-orange) than calm black.
        XCTAssertGreaterThan(ask.r, calm.r)
    }
}
