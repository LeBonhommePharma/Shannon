// PetSpriteCompanion.swift — optional Codex spritesheet draw path.
//
// When a v2 package is resolved, CompanionView can crop atlas frames for the
// mapped PetCodexMotion. Without a package — or when the sheet fails to load /
// crop — procedural CompanionArt is used (no blank companion). Package presence
// is optional.

import Foundation
#if canImport(SwiftUI)
import SwiftUI
import AppKit
#endif

/// Cache of loaded spritesheets keyed by package path.
@available(macOS 14.0, *)
public final class PetSpriteSheetCache: @unchecked Sendable {
    public static let shared = PetSpriteSheetCache()

    private var images: [String: NSImage] = [:]
    private let lock = NSLock()

    public func image(at url: URL) -> NSImage? {
        let key = url.path
        lock.lock()
        defer { lock.unlock() }
        if let hit = images[key] { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        images[key] = img
        return img
    }

    public func clear() {
        lock.lock()
        images.removeAll()
        lock.unlock()
    }
}

/// Pure crop of one atlas cell from a loaded sheet (no disk I/O beyond cache).
@available(macOS 14.0, *)
public enum PetAtlasRenderer {
    /// True when the package has a loadable spritesheet with at least one cell.
    public static func isDrawable(package: PetPackage) -> Bool {
        guard let url = package.spritesheetURL,
              !package.useProcedural,
              let nsImage = PetSpriteSheetCache.shared.image(at: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }
        return cg.width >= PetAtlasGrid.cellWidth
            && cg.height >= PetAtlasGrid.cellHeight
    }

    /// Crop one frame. Returns nil when the sheet is missing, unloadable, or
    /// the crop is out of bounds — callers must fall back to procedural art.
    public static func frameImage(
        package: PetPackage,
        motion: PetCodexMotion,
        tSeconds: Double
    ) -> CGImage? {
        guard let url = package.spritesheetURL,
              let nsImage = PetSpriteSheetCache.shared.image(at: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let frame = PetAtlasFrame.select(motion: motion, tSeconds: tSeconds)
        // Scale crop if the sheet is not native interop size.
        let sx = CGFloat(cgImage.width) / CGFloat(PetAtlasGrid.atlasWidth)
        let sy: CGFloat = {
            if cgImage.height >= PetAtlasGrid.extendedHeight {
                return CGFloat(cgImage.height) / CGFloat(PetAtlasGrid.extendedHeight)
            }
            if cgImage.height >= PetAtlasGrid.standardHeight {
                return CGFloat(cgImage.height) / CGFloat(PetAtlasGrid.standardHeight)
            }
            let rows = cgImage.height >= PetAtlasGrid.cellHeight * 11
                ? 11
                : max(1, cgImage.height / PetAtlasGrid.cellHeight)
            return CGFloat(cgImage.height) / CGFloat(rows * PetAtlasGrid.cellHeight)
        }()

        let cellW = CGFloat(frame.width) * sx
        let cellH = CGFloat(frame.height) * sy
        let srcX = CGFloat(frame.x) * sx
        // CGImage origin is bottom-left; atlas y is top-down.
        let srcY = CGFloat(cgImage.height) - CGFloat(frame.y) * sy - cellH
        let src = CGRect(x: srcX, y: srcY, width: cellW, height: cellH)
        guard src.width >= 1, src.height >= 1,
              src.minX >= 0, src.minY >= 0,
              src.maxX <= CGFloat(cgImage.width) + 0.5,
              src.maxY <= CGFloat(cgImage.height) + 0.5
        else { return nil }
        return cgImage.cropping(to: src.integral)
    }
}

/// Resolved draw mode for a companion surface.
public enum CompanionDrawMode: Sendable, Equatable {
    case procedural
    case atlas(package: PetPackage, motion: PetCodexMotion)

    public var usesPackage: Bool {
        if case .atlas = self { return true }
        return false
    }

    /// Choose atlas when a non-procedural, *drawable* package is available.
    /// Unloadable sheets fall through to procedural (no blank UI).
    public static func resolve(
        petId: String = PetPackageResolver.defaultPetId,
        motion: PetCodexMotion,
        roots: [URL]? = nil
    ) -> CompanionDrawMode {
        let pkg = PetPackageResolver.resolve(petId: petId, roots: roots, requireV2: true)
        if pkg.useProcedural || pkg.spritesheetURL == nil {
            return .procedural
        }
        #if canImport(AppKit)
        if #available(macOS 14.0, *), !PetAtlasRenderer.isDrawable(package: pkg) {
            return .procedural
        }
        #endif
        return .atlas(package: pkg, motion: motion)
    }
}

#if canImport(SwiftUI)
/// Draws one atlas cell from a Codex spritesheet.
/// Returns an empty view when the crop fails — **callers must fall back**
/// to procedural art (see `CompanionView`). Prefer `PetAtlasRenderer.frameImage`
/// so the parent can switch paths without a blank companion.
@available(macOS 14.0, *)
public struct PetAtlasSpriteView: View {
    public let package: PetPackage
    public let motion: PetCodexMotion
    public let size: CGFloat
    public let tSeconds: Double

    public init(package: PetPackage, motion: PetCodexMotion, size: CGFloat, tSeconds: Double) {
        self.package = package
        self.motion = motion
        self.size = size
        self.tSeconds = tSeconds
    }

    public static func isDrawable(package: PetPackage) -> Bool {
        PetAtlasRenderer.isDrawable(package: package)
    }

    public var body: some View {
        Group {
            if let cg = PetAtlasRenderer.frameImage(
                package: package, motion: motion, tSeconds: tSeconds
            ) {
                Canvas { ctx, sz in
                    ctx.draw(Image(decorative: cg, scale: 1), in: CGRect(origin: .zero, size: sz))
                }
            } else {
                // Intentionally empty — CompanionView must not use this branch
                // alone; it falls back to procedural when frameImage is nil.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
