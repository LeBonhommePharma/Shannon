#if canImport(SwiftUI)
import SwiftUI

// MARK: - Shared host capacity cards (iOS / iPad / watchOS / Mac previews)
//
// Lightweight views so companions are not left on battery-only while Mac
// gains SSD + thermal. Pure layout over HostCapacitySnapshot.

/// Compact multi-gauge host card: most constrained first, then remaining.
@available(iOS 16.0, macOS 13.0, watchOS 9.0, *)
public struct HostCapacityCard: View {
    public var title: String
    public var capacity: HostCapacitySnapshot?
    public var platformSymbol: String

    public init(
        title: String = "Host",
        capacity: HostCapacitySnapshot?,
        platformSymbol: String = "laptopcomputer"
    ) {
        self.title = title
        self.capacity = capacity
        self.platformSymbol = platformSymbol
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: platformSymbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if let top = capacity?.mostConstrained {
                    Text(top.shortLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint(for: top.percent))
                } else {
                    Text("—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let cap = capacity, !cap.constrainedRanked.isEmpty {
                ForEach(cap.constrainedRanked.prefix(5)) { row in
                    gaugeRow(row)
                }
                if let free = cap.diskFreeGB, cap.diskTotalGB != nil {
                    Text(String(format: "%.0f GB free", free))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let therm = cap.thermal {
                    Text("Thermal · \(therm.label)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No host capacity yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let cap = capacity, let top = cap.mostConstrained else {
            return "\(title), host capacity unavailable"
        }
        return "\(title), most constrained \(top.shortLabel)"
    }

    @ViewBuilder
    private func gaugeRow(_ row: HostConstrainedResource) -> some View {
        HStack(spacing: 6) {
            Image(systemName: row.kind.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint(for: row.percent))
                .frame(width: 14)
            Text(row.kind.shortLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(width: 36, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(tint(for: row.percent).opacity(0.9))
                        .frame(width: max(3, geo.size.width * CGFloat(row.percent / 100)))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.0f%%", row.percent))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint(for: row.percent))
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 14)
    }

    private func tint(for percent: Double) -> Color {
        switch HostCapacityLogic.band(for: percent) {
        case .calm: return .green
        case .elevated: return .blue
        case .hot: return .orange
        case .critical: return .red
        }
    }
}

/// Watch-sized one-liner: most constrained only.
@available(watchOS 9.0, iOS 16.0, macOS 13.0, *)
public struct HostCapacityChip: View {
    public var capacity: HostCapacitySnapshot?

    public init(capacity: HostCapacitySnapshot?) {
        self.capacity = capacity
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 10, weight: .semibold))
            if let top = capacity?.mostConstrained {
                Text(top.shortLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            } else {
                Text("Load —")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(capacity?.mostConstrained?.shortLabel ?? "Load unknown")
    }
}
#endif
