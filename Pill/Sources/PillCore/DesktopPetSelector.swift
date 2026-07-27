// DesktopPetSelector.swift — pure model for Settings desktop-pet picker.
//
// Builds a stable, browsable list of Codex/Shannon v2 package options for the
// floating companion. UI only binds selection to `ShannonPreferencesStore`.

import Foundation

/// One row in the Settings pet selector (pure; no AppKit).
public struct DesktopPetOption: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { petId }
    public let petId: String
    public let displayName: String
    public let detail: String
    /// True when a real package root was resolved (not a procedural fallback).
    public let isInstalled: Bool

    public init(
        petId: String,
        displayName: String,
        detail: String = "",
        isInstalled: Bool = true
    ) {
        self.petId = petId.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name.isEmpty ? self.petId : name
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isInstalled = isInstalled
    }
}

/// Pure helpers for the desktop pet picker list + selection policy.
public enum DesktopPetSelector: Sendable {

    /// Build selectable options from discovered packages + current/default ids.
    ///
    /// - Always includes `defaultPetId` and `currentPetId` so the picker never
    ///   strands the store on an orphan id.
    /// - Sorted by display name (stable), then petId.
    public static func options(
        packages: [PetPackage],
        currentPetId: String,
        defaultPetId: String = PetPackageResolver.defaultPetId
    ) -> [DesktopPetOption] {
        var byId: [String: DesktopPetOption] = [:]
        for pkg in packages {
            let id = pkg.petId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            byId[id] = DesktopPetOption(
                petId: id,
                displayName: pkg.displayName.isEmpty ? id : pkg.displayName,
                detail: pkg.description,
                isInstalled: !pkg.useProcedural && pkg.root != nil
            )
        }
        let def = ShannonPreferences.normalizeDesktopPetId(defaultPetId)
        if byId[def] == nil {
            byId[def] = DesktopPetOption(
                petId: def,
                displayName: prettyLabel(def),
                detail: "Default Shannon companion",
                isInstalled: false
            )
        }
        let cur = ShannonPreferences.normalizeDesktopPetId(currentPetId)
        if byId[cur] == nil {
            byId[cur] = DesktopPetOption(
                petId: cur,
                displayName: prettyLabel(cur),
                detail: "Currently selected",
                isInstalled: false
            )
        }
        return byId.values.sorted { a, b in
            if a.displayName.localizedCaseInsensitiveCompare(b.displayName) != .orderedSame {
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
            return a.petId < b.petId
        }
    }

    /// Discover packages from disk roots (shipped Settings path).
    public static func optionsFromDisk(
        currentPetId: String,
        requireV2: Bool = true,
        roots: [URL]? = nil
    ) -> [DesktopPetOption] {
        let packages = PetPackageResolver.listPetPackages(
            roots: roots,
            requireV2: requireV2
        )
        return options(
            packages: packages,
            currentPetId: currentPetId,
            defaultPetId: PetPackageResolver.defaultPetId
        )
    }

    /// Human label for a bare package id (`shannon-hub` → `Shannon Hub`).
    public static func prettyLabel(_ petId: String) -> String {
        let raw = petId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return PetPackageResolver.defaultPetId }
        return raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { part -> String in
                let s = String(part)
                guard let first = s.first else { return s }
                return String(first).uppercased() + s.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// Whether `petId` is among the selectable options (after normalize).
    /// Package ids are case-insensitive for selection matching.
    public static func contains(
        petId: String,
        in options: [DesktopPetOption]
    ) -> Bool {
        let id = ShannonPreferences.normalizeDesktopPetId(petId).lowercased()
        return options.contains { $0.petId.lowercased() == id }
    }
}
