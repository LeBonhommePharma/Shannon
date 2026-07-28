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

    /// Display type. `.largeTitle` · bold · **default SF Pro** (native, not rounded
    /// chrome — rounded is reserved for rare marketing display only).
    static let shannonLargeTitle = Font.system(.largeTitle, design: .default, weight: .bold)

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

    // MARK: Menubar + notch chrome (AgentNotch density on macOS 27)

    /// Popover / pill section headers — 10pt semibold, uppercase tracking in views.
    static let shannonMenuSection = Font.system(size: 10, weight: .semibold, design: .default)

    /// Primary menubar popover title (e.g. "Shannon") — AgentNotch-class HUD title.
    static let shannonMenuTitle = Font.system(size: 13, weight: .semibold, design: .default)

    /// Secondary line under titles.
    static let shannonMenuSubtitle = Font.system(size: 11, weight: .regular, design: .default)

    /// Body rows in the status popover (agent names, tips).
    static let shannonMenuBody = Font.system(size: 12, weight: .semibold, design: .default)

    /// Supporting popover copy.
    static let shannonMenuFootnote = Font.system(size: 11, weight: .regular, design: .default)

    /// Telemetry numbers in the menubar (H, %, RMSD) — SF Mono.
    static let shannonMenuMono = Font.system(size: 11, weight: .semibold, design: .monospaced)

    /// Collapsed notch focus line — scannable at island density.
    static let shannonPillLabel = Font.system(size: 12, weight: .semibold, design: .default)

    /// Collapsed notch numeric H — SF Mono, same optical size as pill label.
    static let shannonPillMono = Font.system(size: 12, weight: .semibold, design: .monospaced)
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
        .init("shannonLargeTitle", .shannonLargeTitle, usage: "largeTitle · bold · SF Pro"),
        .init("shannonTitle", .shannonTitle, usage: "title2 · semibold · SF Pro"),
        .init("shannonHeadline", .shannonHeadline, usage: "headline · semibold · SF Pro"),
        .init("shannonBody", .shannonBody, usage: "body · regular · SF Pro"),
        .init("shannonCallout", .shannonCallout, usage: "callout · medium · SF Pro"),
        .init("shannonCaption", .shannonCaption, usage: "caption · regular · SF Pro"),
        .init("shannonMono", .shannonMono, usage: "caption · regular · SF Mono"),
        .init("shannonMenuSection", .shannonMenuSection, usage: "10pt · semibold · SF Pro · HUD section"),
        .init("shannonMenuTitle", .shannonMenuTitle, usage: "13pt · semibold · SF Pro · HUD title"),
        .init("shannonMenuSubtitle", .shannonMenuSubtitle, usage: "11pt · regular · SF Pro"),
        .init("shannonMenuBody", .shannonMenuBody, usage: "12pt · semibold · SF Pro · roster"),
        .init("shannonMenuFootnote", .shannonMenuFootnote, usage: "11pt · regular · SF Pro"),
        .init("shannonMenuMono", .shannonMenuMono, usage: "11pt · semibold · SF Mono"),
        .init("shannonPillLabel", .shannonPillLabel, usage: "12pt · semibold · SF Pro · island focus"),
        .init("shannonPillMono", .shannonPillMono, usage: "12pt · semibold · SF Mono · island H"),
    ]
}
