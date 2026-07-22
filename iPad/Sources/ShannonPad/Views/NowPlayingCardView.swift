import SwiftUI
import ShannonCore
import ShannonTheme
#if canImport(UIKit)
import UIKit
#endif

/// Album art, a waveform-shaped scrubber, and transport.
///
/// Every control here is a request to the Mac, not a local playback change —
/// the iPad is a remote, and the round trip is visible in that the UI waits for
/// the next snapshot rather than optimistically flipping the play glyph.
struct NowPlayingCardView: View {
    var media: NowPlayingSnapshot
    var isCompact: Bool = false
    var onCommand: (PlaybackCommand) -> Void
    var onOpenInMusic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.md) {
            HStack(spacing: ShannonSpacing.md) {
                Artwork(data: media.artworkJPEG)
                    .frame(width: isCompact ? 48 : 64, height: isCompact ? 48 : 64)

                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title.isEmpty ? "Nothing playing" : media.title)
                        .shannonText(.shannonHeadline)
                        .lineLimit(1)
                    Text(media.artist)
                        .shannonText(.shannonCaption, color: .shannonSecondary)
                        .lineLimit(1)
                    if !isCompact, !media.album.isEmpty {
                        Text(media.album)
                            .shannonText(.shannonCaption, color: .shannonTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            Waveform(progress: media.progress, isPlaying: media.isPlaying)
                .frame(height: isCompact ? 22 : 32)

            HStack(spacing: ShannonSpacing.lg) {
                transport(.previousTrack, "backward.fill")
                transport(
                    .togglePlayPause,
                    media.isPlaying ? "pause.fill" : "play.fill",
                    isPrimary: true
                )
                transport(.nextTrack, "forward.fill")

                Spacer()

                Text(timeLabel)
                    .shannonNumeric()
            }
        }
        .shannonCard()
        .contextMenu {
            Button { onCommand(.nextTrack) } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Button(action: onOpenInMusic) {
                Label("Open in Music", systemImage: "arrow.up.forward.app")
            }
        }
    }

    private func transport(
        _ command: PlaybackCommand,
        _ symbol: String,
        isPrimary: Bool = false
    ) -> some View {
        Button { onCommand(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: isPrimary ? 22 : 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPrimary ? Color.shannonAccent : Color.shannonPrimary)
        .accessibilityLabel(command.rawValue)
    }

    private var timeLabel: String {
        func clock(_ seconds: Double) -> String {
            guard seconds.isFinite, seconds >= 0 else { return "0:00" }
            let total = Int(seconds)
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return "\(clock(media.elapsed)) / \(clock(media.duration))"
    }
}

/// Album art, or an accent-tinted placeholder when the Mac had none to send.
private struct Artwork: View {
    var data: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ShannonRadius.md, style: .continuous)
                .fill(Color.shannonSurfaceElevated)

            #if canImport(UIKit)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: ShannonRadius.md, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.title2)
            .foregroundStyle(Color.shannonTertiary)
    }
}

/// A deterministic bar field, tinted up to the playback position.
///
/// It is a scrubber drawn as a waveform, not an analysis of the audio — the
/// Mac sends no samples. The shape is seeded from the bar index so it stays
/// still between frames instead of jittering like a fake spectrum.
private struct Waveform: View {
    var progress: Double
    var isPlaying: Bool

    private let barCount = 56

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let width = max((geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount), 1)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let played = Double(index) / Double(barCount) <= progress
                    Capsule()
                        .fill(played ? Color.shannonAccent : Color.shannonSurfaceElevated)
                        .frame(width: width, height: geo.size.height * height(at: index))
                }
            }
            .frame(height: geo.size.height, alignment: .center)
            .opacity(isPlaying ? 1 : 0.55)
            .animation(.shannonEase, value: progress)
            .animation(.shannonSnap, value: isPlaying)
        }
    }

    private func height(at index: Int) -> Double {
        let phase = Double(index)
        let envelope = sin(phase * 0.37) * 0.32 + sin(phase * 0.11) * 0.24 + sin(phase * 0.9) * 0.14
        return min(max(0.5 + envelope, 0.18), 1.0)
    }
}
