import SwiftUI
import PillCore

/// Shannon product Settings — fixed chrome, system typography, no thrash.
///
/// Only toggles the app actually honors. Disk folder / hub log are actions,
/// not fake preferences.
struct SettingsView: View {
    @ObservedObject var store: ShannonPreferencesStore
    var onOpenShannonHome: () -> Void
    var onOpenHubLog: () -> Void
    var onDone: () -> Void

    /// Fixed size — matches popover anti-pop discipline.
    static let chromeWidth: CGFloat = 360
    static let chromeHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    keepAwakeSection
                    pillSection
                    desktopSection
                    desktopPetSection
                    agentsSection
                    tipsSection
                    dataSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer
        }
        .frame(width: Self.chromeWidth, height: Self.chromeHeight, alignment: .top)
        .transaction { txn in
            txn.animation = nil
            txn.disablesAnimations = true
        }
        .background {
            ZStack {
                PillMaterial(kind: .popover)
                Color.shannonBackground.opacity(0.28)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.fill")
                .font(.shannonMenuTitle)
                .foregroundStyle(Color.shannonAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Shannon Settings")
                    .font(.shannonMenuTitle)
                    .foregroundStyle(Color.shannonPrimary)
                Text("Preferences that change live behavior")
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonSecondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private var keepAwakeSection: some View {
        settingsCard(title: "Keep awake") {
            Toggle(isOn: $store.autoKeepAwakeWithAgents) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto while agents busy")
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonPrimary)
                    Text("Hold idle + display sleep when work is running")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var pillSection: some View {
        settingsCard(title: "Notch pill") {
            Toggle(isOn: $store.expandPillOnLaunch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expand on launch")
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonPrimary)
                    Text("Brief hello board, then tuck into the notch")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var desktopSection: some View {
        settingsCard(title: "Desktop companion") {
            Toggle(isOn: $store.showDesktopCompanion) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show desktop pet")
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonPrimary)
                    Text("Floating pet and status bubble (menu ⌥-click also toggles)")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }


    /// Package picker for the floating desktop companion (E1).
    private var desktopPetSection: some View {
        settingsCard(title: "Desktop pet package") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Package")
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonPrimary)
                    Text("Codex spritesheet used by the floating companion")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
                Picker("Package", selection: $store.desktopPetId) {
                    ForEach(availableDesktopPetIds, id: \.self) { petId in
                        Text(petId).tag(petId)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        }
    }

    /// Discoverable package ids + default + current selection (always selectable).
    private var availableDesktopPetIds: [String] {
        var ids = PetPackageResolver.listPetPackageIds(requireV2: true)
        let fallback = PetPackageResolver.defaultPetId
        if !ids.contains(fallback) {
            ids.insert(fallback, at: 0)
        }
        let current = store.desktopPetId
        if !ids.contains(current) {
            ids.append(current)
            ids.sort()
        }
        return ids
    }

    private var agentsSection: some View {
        settingsCard(title: "Agents") {
            Toggle(isOn: $store.startWithMonitoringPaused) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start with monitoring paused")
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonPrimary)
                    Text("Do not poll the gate until you resume from the menu")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var tipsSection: some View {
        settingsCard(title: "Tips") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.firstRunDone ? "First-run tips dismissed" : "First-run tips pending")
                        .font(.shannonMenuBody)
                        .foregroundStyle(Color.shannonPrimary)
                    Text("Coach shown when the agent roster is empty")
                        .font(.shannonMenuFootnote)
                        .foregroundStyle(Color.shannonTertiary)
                }
                Spacer(minLength: 8)
                Button("Reset tips") {
                    store.resetFirstRunCoach()
                }
                .font(.shannonMenuBody)
                .buttonStyle(.plain)
                .foregroundStyle(Color.shannonAccent)
                .disabled(!store.firstRunDone)
                .opacity(store.firstRunDone ? 1 : 0.4)
            }
        }
    }

    private var dataSection: some View {
        settingsCard(title: "Data") {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onOpenShannonHome) {
                    labelRow(systemImage: "folder", title: "Open ~/.shannon", subtitle: "Pets, registry, hub DB")
                }
                .buttonStyle(.plain)
                Button(action: onOpenHubLog) {
                    labelRow(systemImage: "doc.text", title: "Open hub log", subtitle: "Library/Logs/Shannon")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func labelRow(systemImage: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.shannonMenuBody)
                .foregroundStyle(Color.shannonAccent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.shannonMenuBody)
                    .foregroundStyle(Color.shannonPrimary)
                Text(subtitle)
                    .font(.shannonMenuFootnote)
                    .foregroundStyle(Color.shannonTertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonTertiary)
        }
        .contentShape(Rectangle())
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.shannonMenuSection)
                .foregroundStyle(Color.shannonTertiary)
                .tracking(0.6)
            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
    }

    private var footer: some View {
        HStack {
            Text("Changes apply immediately")
                .font(.shannonMenuFootnote)
                .foregroundStyle(Color.shannonTertiary)
            Spacer()
            Button("Done", action: onDone)
                .font(.shannonMenuBody)
                .buttonStyle(.plain)
                .foregroundStyle(Color.shannonAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.shannonAccent.opacity(0.15))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: 44)
        .background(Color.black.opacity(0.22))
    }
}
