// PetPackageBinding.swift — agent id / style → Codex atlas package id (B3).
import Foundation

public enum PetPackageBinding {
    public static let packageIdByAgentId: [String: String] = [
        "grok_build": "grok", "grok": "grok", "supergrok": "grok",
        "science": "shannon", "cursor": "bonhomme-cat", "codex": "shannon",
        "claude_code": "shannon", "design": "firebear", "chatgpt": "shannon",
        "cowork": "bonhomme", "dispatch": "firebear", "terminal": "shannon",
        "browser": "shannon", "vscode": "shannon", "dataset_runner": "shannon",
    ]
    public static let packageIdByStylePet: [String: String] = [
        "raven": "grok", "cat": "bonhomme-cat", "owl": "shannon", "fox": "shannon",
        "dolphin": "shannon", "wolf": "firebear", "beaver": "bonhomme", "gear": "shannon",
    ]
    public static func preferredPackageId(
        forAgentId agentId: String,
        preferenceOverride: String? = nil,
        style: AgentStyle? = nil
    ) -> String {
        if let raw = preferenceOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        let id = agentId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_")
        if id.isEmpty { return PetPackageResolver.defaultPetId }
        if let mapped = packageIdByAgentId[id] { return mapped }
        if packageIdByAgentId.values.contains(id) || id == PetPackageResolver.defaultPetId { return id }
        let resolvedStyle = style ?? AgentStyleCatalog.style(for: agentId)
        let pet = resolvedStyle.pet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = packageIdByStylePet[pet] { return mapped }
        return PetPackageResolver.defaultPetId
    }
}

public extension PetPackageResolver {
    static func preferredPackageId(
        forAgentId agentId: String,
        preferenceOverride: String? = nil,
        style: AgentStyle? = nil
    ) -> String {
        PetPackageBinding.preferredPackageId(
            forAgentId: agentId, preferenceOverride: preferenceOverride, style: style
        )
    }
    static var packageIdByAgentId: [String: String] { PetPackageBinding.packageIdByAgentId }
    static var packageIdByStylePet: [String: String] { PetPackageBinding.packageIdByStylePet }
}
