import XCTest
import SwiftUI
@testable import ShannonTheme

final class ShannonThemeTests: XCTestCase {

    func testHexDecodesToSRGBComponents() {
        let accent = ShannonRGBA(hex: 0x3A5CF5)
        XCTAssertEqual(accent.red, 0x3A / 255, accuracy: 1e-9)
        XCTAssertEqual(accent.green, 0x5C / 255, accuracy: 1e-9)
        XCTAssertEqual(accent.blue, 0xF5 / 255, accuracy: 1e-9)
        XCTAssertEqual(accent.alpha, 1.0, accuracy: 1e-9)
    }

    func testHexCarriesStraightAlpha() {
        let tint = ShannonRGBA(hex: 0xFFFFFF, alpha: 0.72)
        XCTAssertEqual(tint.alpha, 0.72, accuracy: 1e-9)
        XCTAssertEqual(tint.red, 1.0, accuracy: 1e-9)
    }

    func testNightBackgroundIsNotPureBlack() {
        // The whole point of #0D0D10 over #000000 — keep the warm undertone.
        let night = ShannonRGBA(hex: 0x0D0D10)
        XCTAssertGreaterThan(night.red, 0)
        XCTAssertGreaterThan(night.blue, night.red, "night background keeps a cool-warm lift")
    }

    func testSpacingFollowsEightPointGrid() {
        let steps: [CGFloat] = [
            ShannonSpacing.sm, ShannonSpacing.md,
            ShannonSpacing.lg, ShannonSpacing.xl, ShannonSpacing.xxl,
        ]
        for step in steps {
            XCTAssertEqual(step.truncatingRemainder(dividingBy: 8), 0, "\(step) is off-grid")
        }
        XCTAssertEqual(ShannonSpacing.xs, 4, "xs is the single permitted half-step")
    }

    func testSpacingIsMonotonic() {
        let ordered: [CGFloat] = [
            ShannonSpacing.xs, ShannonSpacing.sm, ShannonSpacing.md,
            ShannonSpacing.lg, ShannonSpacing.xl, ShannonSpacing.xxl,
        ]
        XCTAssertEqual(ordered, ordered.sorted())
    }

    func testColorCatalogueCoversEveryGroup() {
        XCTAssertEqual(ShannonColorCatalogue.all.count, 15)
        XCTAssertEqual(ShannonColorCatalogue.groups.count, 5)
        let names = Set(ShannonColorCatalogue.all.map(\.name))
        XCTAssertEqual(names.count, ShannonColorCatalogue.all.count, "token names must be unique")
        XCTAssertTrue(names.contains("pillBorderActive"))
        XCTAssertTrue(names.contains("shannonAccentSubtle"))
    }

    func testTypeCatalogueHasSevenTokens() {
        XCTAssertEqual(ShannonTypeCatalogue.all.count, 7)
        XCTAssertEqual(Set(ShannonTypeCatalogue.all.map(\.name)).count, 7)
    }

    func testExpandedPillHeightAddsThirtyTwoPoints() {
        XCTAssertEqual(ShannonLayout.Pill.expandedHeight(contentHeight: 100), 132)
        XCTAssertEqual(ShannonLayout.Pill.expandedWidth, 320)
        XCTAssertEqual(ShannonLayout.Pill.collapsedWidth, 160)
        XCTAssertEqual(ShannonLayout.Pill.collapsedHeight, 32)
    }

    func testCardInsetsMatchSpec() {
        XCTAssertEqual(ShannonLayout.IOSCard.totalHorizontalInset, 32)
        XCTAssertEqual(ShannonLayout.IOSCard.radius, 16)
        XCTAssertEqual(ShannonLayout.WatchCard.radius, 12)
        XCTAssertEqual(ShannonLayout.WatchCard.padding, 8)
        XCTAssertEqual(ShannonLayout.WatchCard.maxTextLines, 2)
    }
}
