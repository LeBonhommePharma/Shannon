import SwiftUI

// MARK: - Type scale
//
// Every token is built from a *text style* (`.largeTitle`, `.body`, …) rather
// than a fixed point size, so Dynamic Type scaling is automatic and
// `.dynamicTypeSize(...)` clamps work as expected at the call site.
//
// SF Rounded is reserved for the largest display type — it gives the numerals a
// friendlier shoulder without softening body copy. Everything else is SF Pro.
// SF Mono is for anything the eye needs to compare column-wise: RMSD values,
// CF scores, entropy in bits, turn counts.

public extension Font {

    /// Display type. `.largeTitle` · bold · SF Rounded
    static let shannonLargeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)

    /// Screen and section titles. `.title2` · semibold · SF Pro
    static let shannonTitle = Font.system(.title2, design: .default, weight: .semibold)

    /// Card headers, row titles. `.headline` · semibold · SF Pro
    static let shannonHeadline = Font.system(.headline, design: .default, weight: .semibold)

    /// Body copy. `.body` · regular · SF Pro
    static let shannonBody = Font.system(.body, design: .default, weight: .regular)

    /// Buttons and emphasised inline labels. `.callout` · medium · SF Pro
    static let shannonCallout = Font.system(.callout, design: .default, weight: .medium)

    /// Metadata and captions. `.caption` · regular · SF Pro, monospaced digits
    /// so counters do not jitter as they tick.
    static let shannonCaption = Font.system(.caption, design: .default, weight: .regular)
        .monospacedDigit()

    /// Numeric readouts — RMSD, CF scores, turn counts, entropy in bits.
    /// `.caption` · regular · SF Mono
    static let shannonMono = Font.system(.caption, design: .monospaced, weight: .regular)
}

// MARK: - Text style modifiers

public extension View {
    /// Applies a font token plus its canonical foreground colour in one call.
    func shannonText(_ font: Font, color: Color = .shannonPrimary) -> some View {
        self.font(font).foregroundStyle(color)
    }

    /// Numeric readout styling: mono face, secondary weight of attention,
    /// and a Dynamic Type ceiling so tabular columns keep their alignment.
    func shannonNumeric(color: Color = .shannonSecondary) -> some View {
        self.font(.shannonMono)
            .foregroundStyle(color)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

// MARK: - Catalogue

public struct ShannonFontToken: Identifiable, Sendable {
    public let name: String
    public let font: Font
    public let usage: String

    public var id: String { name }

    public init(_ name: String, _ font: Font, usage: String) {
        self.name = name
        self.font = font
        self.usage = usage
    }
}

public enum ShannonTypeCatalogue {
    public static let all: [ShannonFontToken] = [
        .init("shannonLargeTitle", .shannonLargeTitle, usage: "largeTitle · bold · SF Rounded"),
        .init("shannonTitle", .shannonTitle, usage: "title2 · semibold · SF Pro"),
        .init("shannonHeadline", .shannonHeadline, usage: "headline · semibold · SF Pro"),
        .init("shannonBody", .shannonBody, usage: "body · regular · SF Pro"),
        .init("shannonCallout", .shannonCallout, usage: "callout · medium · SF Pro"),
        .init("shannonCaption", .shannonCaption, usage: "caption · regular · SF Pro"),
        .init("shannonMono", .shannonMono, usage: "caption · regular · SF Mono"),
    ]
}
