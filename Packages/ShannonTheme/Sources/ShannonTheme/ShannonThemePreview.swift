#if DEBUG
import SwiftUI

/// A live specimen sheet for the whole design system: every semantic colour,
/// the full type scale, the spacing grid, and the pill in both states.
///
/// Open this file in Xcode and the canvas renders Day and Night side by side.
/// It is the fastest way to check a new token against the rest of the palette
/// before it ships.
public struct ShannonThemeSpecimen: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShannonSpacing.lg) {
                header
                colorSection
                typeSection
                #if os(macOS)
                pillSection
                #endif
                spacingSection
            }
            .padding(ShannonSpacing.md)
        }
        .background(Color.shannonBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
            Text("Shannon")
                .font(.shannonLargeTitle)
                .foregroundStyle(Color.shannonPrimary)
            Text("Design system specimen")
                .font(.shannonCallout)
                .foregroundStyle(Color.shannonSecondary)
        }
    }

    // MARK: Colour

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.md) {
            sectionTitle("Semantic colours")
            ForEach(ShannonColorCatalogue.groups, id: \.0) { group, tokens in
                VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
                    Text(group.uppercased())
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonTertiary)
                    ForEach(tokens) { token in
                        swatch(token)
                    }
                }
            }
        }
        .padding(ShannonSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: ShannonRadius.lg, style: .continuous)
                .fill(Color.shannonSurface)
        )
    }

    private func swatch(_ token: ShannonColorToken) -> some View {
        HStack(spacing: ShannonSpacing.sm) {
            RoundedRectangle(cornerRadius: ShannonRadius.sm, style: .continuous)
                .fill(token.color)
                .frame(width: 40, height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: ShannonRadius.sm, style: .continuous)
                        .strokeBorder(Color.shannonTertiary.opacity(0.4), lineWidth: 0.5)
                }
            Text(token.name)
                .font(.shannonMono)
                .foregroundStyle(Color.shannonSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Type

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.md) {
            sectionTitle("Type scale")
            ForEach(ShannonTypeCatalogue.all) { token in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Entropy collapse: 8.4 → 2.1 bits")
                        .font(token.font)
                        .foregroundStyle(Color.shannonPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(token.name) — \(token.usage)")
                        .font(.shannonCaption)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
        }
        .padding(ShannonSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: ShannonRadius.lg, style: .continuous)
                .fill(Color.shannonSurface)
        )
    }

    // MARK: Pill

    #if os(macOS)
    private var pillSection: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.md) {
            sectionTitle("macOS pill")

            HStack(spacing: ShannonSpacing.sm) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.shannonSecondary)
                Text("idle")
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonSecondary)
            }
            .padding(.horizontal, ShannonSpacing.sm)
            .frame(
                width: ShannonLayout.Pill.collapsedWidth,
                height: ShannonLayout.Pill.collapsedHeight
            )
            .shannonPill(isActive: false)

            HStack(spacing: ShannonSpacing.sm) {
                ShannonStatusDot(state: .active)
                Text("agent running")
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonPrimary)
                Spacer(minLength: 0)
                Text("δ −3.4")
                    .font(.shannonMono)
                    .foregroundStyle(Color.shannonAccent)
            }
            .padding(.horizontal, ShannonSpacing.sm)
            .frame(
                width: ShannonLayout.Pill.collapsedWidth,
                height: ShannonLayout.Pill.collapsedHeight
            )
            .shannonPill(isActive: true)
        }
        .padding(ShannonSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: ShannonRadius.lg, style: .continuous)
                .fill(Color.shannonSurfaceElevated)
        )
    }
    #endif

    // MARK: Spacing

    private var spacingSection: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            sectionTitle("Spacing — 8pt grid")
            ForEach(
                [
                    ("xs", ShannonSpacing.xs), ("sm", ShannonSpacing.sm),
                    ("md", ShannonSpacing.md), ("lg", ShannonSpacing.lg),
                    ("xl", ShannonSpacing.xl), ("xxl", ShannonSpacing.xxl),
                ],
                id: \.0
            ) { name, value in
                HStack(spacing: ShannonSpacing.sm) {
                    Rectangle()
                        .fill(Color.shannonAccent)
                        .frame(width: value, height: 12)
                    Text("\(name) — \(Int(value))pt")
                        .font(.shannonMono)
                        .foregroundStyle(Color.shannonSecondary)
                }
            }
        }
        .padding(ShannonSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: ShannonRadius.lg, style: .continuous)
                .fill(Color.shannonSurface)
        )
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.shannonHeadline)
            .foregroundStyle(Color.shannonPrimary)
    }
}

// MARK: - Previews

struct ShannonTheme_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ShannonThemeSpecimen()
                .preferredColorScheme(.light)
                .previewDisplayName("Day")

            ShannonThemeSpecimen()
                .preferredColorScheme(.dark)
                .previewDisplayName("Night")
        }
        .frame(minWidth: 380, minHeight: 700)
    }
}
#endif
