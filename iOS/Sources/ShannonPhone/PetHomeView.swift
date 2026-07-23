import SwiftUI
import AVFoundation
import ShannonCore
import ShannonTheme

// MARK: - PetHomeView

/// Full-screen pet interaction view for iPhone.
/// Swipe up → diary sheet. Tap → playful + haptic. Long press → rename.
/// Voice: "How are you [name]?" → AVSpeechSynthesizer response.
@available(iOS 17.0, *)
struct PetHomeView: View {
    @Environment(PetStore.self) private var store
    @Environment(PetInteractionEngine.self) private var engine

    @State private var showDiary  = false
    @State private var showRename = false
    @State private var petScale: CGFloat = 1

    private let synth = AVSpeechSynthesizer()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.shannonBackground.ignoresSafeArea()
                VStack(spacing: ShannonSpacing.xl) {
                    Spacer()
                    petAvatar
                    Text(store.pet.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.shannonPrimary)
                    moodBadge
                    xpBar
                    Spacer()
                }
            }
            .gesture(swipeUpToDiary)
            .sheet(isPresented: $showDiary)  { PetDiarySheet(store: store) }
            .sheet(isPresented: $showRename) { PetRenameSheet(store: store) }
            .navigationTitle("Pet")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.shannonAccent)
        }
    }

    // MARK: Sub-views

    private var petAvatar: some View {
        PetAvatarCanvas(
            params: PetAvatarDescriptor.params(for: store.pet.avatarSeed),
            mood:   store.pet.mood,
            size:   128
        )
        .scaleEffect(petScale)
        .onTapGesture {
            engine.handle(.tap)
            Haptics.transition()
            bounceAvatar()
        }
        .onLongPressGesture(minimumDuration: 0.4) { showRename = true }
        .accessibilityLabel("\(store.pet.name), feeling \(store.pet.mood.label)")
    }

    private var moodBadge: some View {
        HStack(spacing: ShannonSpacing.xs) {
            Image(systemName: store.pet.mood.symbol)
            Text(store.pet.mood.label)
        }
        .font(.subheadline)
        .foregroundStyle(moodColor)
        .padding(.horizontal, ShannonSpacing.sm)
        .padding(.vertical, 4)
        .background(moodColor.opacity(0.12), in: Capsule())
        .animation(.easeInOut(duration: 0.3), value: store.pet.mood)
    }

    private var xpBar: some View {
        VStack(spacing: 4) {
            ProgressView(value: store.pet.xpFraction)
                .tint(.shannonAccent)
                .frame(width: 200)
            Text("Lv \(store.pet.level) · \(store.pet.xpToNextLevel) XP to next")
                .font(.caption)
                .foregroundStyle(Color.shannonTertiary)
        }
    }

    // MARK: Helpers

    private var swipeUpToDiary: some Gesture {
        DragGesture().onEnded { v in
            if v.translation.height < -60 { showDiary = true }
        }
    }

    private func bounceAvatar() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) { petScale = 1.18 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.spring()) { petScale = 1 }
        }
    }

    /// Speak a response in the pet's "voice" via AVSpeechSynthesizer.
    func speakMoodResponse() {
        let lines: [PetMood: String] = [
            .calm:     "I feel peaceful.",
            .curious:  "Something interesting is happening…",
            .excited:  "Things are moving fast! I love it!",
            .worried:  "I'm a little worried about the errors.",
            .sleeping: "Zzzz…",
            .playful:  "Let's play!"
        ]
        let utt = AVSpeechUtterance(string: lines[store.pet.mood] ?? "I'm here.")
        utt.voice = AVSpeechSynthesisVoice(language: "en-US")
        utt.rate  = 0.48
        synth.speak(utt)
    }

    private var moodColor: Color {
        switch store.pet.mood.colorRole {
        case .blue:   return .shannonAccent
        case .teal:   return Color(hue: 0.5, saturation: 0.7, brightness: 0.7)
        case .amber:  return .shannonWarning
        case .red:    return .shannonError
        case .gray:   return .shannonNeutral
        case .purple: return Color(hue: 0.78, saturation: 0.6, brightness: 0.75)
        }
    }
}

// MARK: - PetDiarySheet

@available(iOS 17.0, *)
struct PetDiarySheet: View {
    let store: PetStore
    @State private var entries: [PetMemoryEntry] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date.formatted(.relative(presentation: .numeric)))
                        .font(.caption)
                        .foregroundStyle(Color.shannonTertiary)
                    Text(entry.text)
                        .font(.body)
                        .foregroundStyle(Color.shannonPrimary)
                }
                .listRowBackground(Color.shannonSurface)
            }
            .listStyle(.plain)
            .background(Color.shannonBackground)
            .navigationTitle("\(store.pet.name)'s Diary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { entries = await PetMemoryStore(petID: store.pet.id).recentEntries(limit: 10) }
    }
}

// MARK: - PetRenameSheet

@available(iOS 17.0, *)
struct PetRenameSheet: View {
    let store: PetStore
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Pet name") {
                    TextField("Name", text: $draft)
                }
            }
            .navigationTitle("Rename \(store.pet.name)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                            store.pet.name = draft
                        }
                        dismiss()
                    }
                }
            }
        }
        .onAppear { draft = store.pet.name }
    }
}
