// PetAtlasFrame.swift — pure Codex v2 atlas frame selection (no image I/O).
//
// Grid: 8 cols × 11 rows, cell 192×208. Standard motion rows 0–8 match
// hatch-pet / Codex interop. Parallel to hub/pet_atlas.py.

import Foundation

/// Geometry constants for Codex-compatible v2 spritesheets.
public enum PetAtlasGrid {
    public static let columns = 8
    public static let standardRows = 9
    public static let extendedRows = 11
    public static let cellWidth = 192
    public static let cellHeight = 208
    public static let atlasWidth = columns * cellWidth           // 1536
    public static let standardHeight = standardRows * cellHeight // 1872
    public static let extendedHeight = extendedRows * cellHeight // 2288
    public static let defaultFPS: Double = 8
}

/// One standard motion row in the atlas.
public struct PetAtlasStateSpec: Sendable, Equatable {
    public let name: String
    public let row: Int
    public let frames: Int
    public let purpose: String
}

public enum PetAtlasCatalog {
    public static let standardStates: [PetAtlasStateSpec] = [
        .init(name: "idle", row: 0, frames: 6, purpose: "calm breathing / blink"),
        .init(name: "running-right", row: 1, frames: 8, purpose: "move screen-right"),
        .init(name: "running-left", row: 2, frames: 8, purpose: "move screen-left"),
        .init(name: "waving", row: 3, frames: 4, purpose: "greeting"),
        .init(name: "jumping", row: 4, frames: 5, purpose: "hop"),
        .init(name: "failed", row: 5, frames: 8, purpose: "error reaction"),
        .init(name: "waiting", row: 6, frames: 6, purpose: "needs user"),
        .init(name: "running", row: 7, frames: 6, purpose: "busy work"),
        .init(name: "review", row: 8, frames: 6, purpose: "inspect output"),
    ]

    public static let byName: [String: PetAtlasStateSpec] = {
        Dictionary(uniqueKeysWithValues: standardStates.map { ($0.name, $0) })
    }()

    public static func normalize(_ motion: String) -> String {
        var key = motion.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let aliases: [String: String] = [
            "busy": "running", "work": "running", "working": "running",
            "alert": "running", "focused": "running",
            "error": "failed", "fail": "failed",
            "blocked": "waiting", "needs-user": "waiting", "ask": "waiting",
            "happy": "waving", "celebrate": "waving", "celebrating": "waving",
            "done": "review", "success": "review",
            "sleepy": "idle", "sleeping": "idle", "resting": "idle",
            "wary": "failed", "uneasy": "failed",
        ]
        key = aliases[key] ?? key
        return byName[key] != nil ? key : "idle"
    }

    public static func spec(for motion: String) -> PetAtlasStateSpec {
        byName[normalize(motion)]!
    }

    public static func spec(for motion: PetCodexMotion) -> PetAtlasStateSpec {
        spec(for: motion.rawValue)
    }
}

/// One selected cell in the spritesheet grid.
public struct PetAtlasFrame: Sendable, Equatable {
    public let motion: String
    public let row: Int
    public let col: Int
    public let frameIndex: Int
    public let framesInRow: Int
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public var rect: (x: Int, y: Int, width: Int, height: Int) {
        (x, y, width, height)
    }

    /// Select the atlas cell for `motion` at time `tSeconds`. Pure: no disk I/O.
    public static func select(
        motion: String,
        tSeconds: Double = 0,
        fps: Double = PetAtlasGrid.defaultFPS,
        frameOffset: Int = 0,
        cellW: Int = PetAtlasGrid.cellWidth,
        cellH: Int = PetAtlasGrid.cellHeight
    ) -> PetAtlasFrame {
        let name = PetAtlasCatalog.normalize(motion)
        let spec = PetAtlasCatalog.byName[name]!
        let col: Int
        if spec.frames <= 1 {
            col = 0
        } else if fps <= 0 {
            col = max(0, frameOffset) % spec.frames
        } else {
            let t = max(0.0, tSeconds)
            col = (Int(t * fps) + max(0, frameOffset)) % spec.frames
        }
        return PetAtlasFrame(
            motion: name,
            row: spec.row,
            col: col,
            frameIndex: col,
            framesInRow: spec.frames,
            x: col * cellW,
            y: spec.row * cellH,
            width: cellW,
            height: cellH
        )
    }

    public static func select(
        motion: PetCodexMotion,
        tSeconds: Double = 0,
        fps: Double = PetAtlasGrid.defaultFPS
    ) -> PetAtlasFrame {
        select(motion: motion.rawValue, tSeconds: tSeconds, fps: fps)
    }

    /// True when the selected frame index advances between t0 and t1.
    public static func advances(
        motion: String,
        from t0: Double,
        to t1: Double,
        fps: Double = PetAtlasGrid.defaultFPS
    ) -> Bool {
        select(motion: motion, tSeconds: t0, fps: fps).frameIndex
            != select(motion: motion, tSeconds: t1, fps: fps).frameIndex
    }
}
