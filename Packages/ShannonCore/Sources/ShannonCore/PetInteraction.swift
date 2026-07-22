import Foundation

// MARK: - PetInteractionKind

/// All ways a user can interact with their pet across every platform.
public enum PetInteractionKind: String, Sendable, CaseIterable {
    case tap
    case doubleTap
    case longPress
    case pencilHover     // Pencil enters the pet's proximity zone (iPad)
    case pencilDraw      // User draws on a PKCanvasView "for" the pet (iPad)
    case voiceCommand    // "How are you [name]?" via AVSpeechRecognizer (iOS)
    case nodConfirm      // AirPods nod gesture (macOS / iOS)
    case shakeDeny       // AirPods shake gesture (macOS / iOS)
    case crownSpin       // Digital Crown rotation (watchOS)
    case doubleTapWatch  // Double Tap gesture (watchOS 11+)
}

// MARK: - PetReactionEvent

/// Published by `PetInteractionEngine` after processing an interaction.
/// Platforms observe this to drive animation + haptics.
public struct PetReactionEvent: Sendable {
    public enum Animation: String, Sendable {
        case bounce, shake, sparkle, spin, blink, flip, pulse
    }
    public var kind: PetInteractionKind
    public var animation: Animation
    public var xpAwarded: Int
    public var memoryText: String?

    public init(kind: PetInteractionKind, animation: Animation,
                xpAwarded: Int, memoryText: String? = nil) {
        self.kind = kind; self.animation = animation
        self.xpAwarded = xpAwarded; self.memoryText = memoryText
    }
}

// MARK: - PetInteractionEngine

/// Receives interactions from any platform, awards XP, appends memory
/// entries, and publishes `PetReactionEvent`s for animation / haptics.
#if canImport(Observation)
import Observation

@available(macOS 14.0, iOS 17.0, watchOS 10.0, *)
@MainActor
@Observable
public final class PetInteractionEngine {
    private let store: PetStore
    private let memory: PetMemoryStore

    /// Platforms set this to drive animations and haptics.
    public var onReaction: ((PetReactionEvent) -> Void)?

    public init(store: PetStore, memory: PetMemoryStore) {
        self.store  = store
        self.memory = memory
    }

    /// Central dispatch point. Call from any platform gesture handler.
    @discardableResult
    public func handle(_ kind: PetInteractionKind) -> PetReactionEvent {
        let event = Self.reaction(for: kind)
        store.awardXP(event.xpAwarded)
        store.markInteracted()
        if let text = event.memoryText {
            Task {
                await memory.append(entry: PetMemoryEntry(kind: .interaction, text: text))
            }
        }
        onReaction?(event)
        return event
    }

    // MARK: Reaction table

    private static func reaction(for kind: PetInteractionKind) -> PetReactionEvent {
        switch kind {
        case .tap:
            return PetReactionEvent(kind: kind, animation: .pulse, xpAwarded: 1)
        case .doubleTap:
            return PetReactionEvent(kind: kind, animation: .bounce, xpAwarded: 2)
        case .longPress:
            return PetReactionEvent(kind: kind, animation: .sparkle, xpAwarded: 3)
        case .pencilHover:
            return PetReactionEvent(kind: kind, animation: .blink, xpAwarded: 0)
        case .pencilDraw:
            return PetReactionEvent(kind: kind, animation: .spin, xpAwarded: 10,
                memoryText: "you drew something beautiful for me")
        case .voiceCommand:
            return PetReactionEvent(kind: kind, animation: .bounce, xpAwarded: 2)
        case .nodConfirm:
            return PetReactionEvent(kind: kind, animation: .bounce, xpAwarded: 3,
                memoryText: "nodded in agreement")
        case .shakeDeny:
            return PetReactionEvent(kind: kind, animation: .shake, xpAwarded: 1,
                memoryText: "shook head in denial")
        case .crownSpin:
            return PetReactionEvent(kind: kind, animation: .spin, xpAwarded: 1)
        case .doubleTapWatch:
            let tricks: [PetReactionEvent.Animation] = [.flip, .bounce, .sparkle]
            let anim = tricks[Int.random(in: 0 ..< tricks.count)]
            return PetReactionEvent(kind: kind, animation: anim, xpAwarded: 5,
                memoryText: "did a trick on Apple Watch")
        }
    }
}

#endif // canImport(Observation)
