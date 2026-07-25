import CoreGraphics

/// Height policy for the notch panel, shared by every path that resizes it.
///
/// The panel is top-anchored on `screen.frame.maxY`, so anything taller than the
/// display is drawn past the top edge and lost rather than scrolled. Two paths
/// set the height — content measurement (`PillContentSizeKey`) and screen
/// changes (`NSApplication.didChangeScreenParametersNotification`) — and they
/// used to clamp differently, so a panel grown tall on a large display carried
/// that height verbatim onto a smaller one. Both go through `clamped` now, which
/// is the whole point of this type: one clamp, no drift.
public enum PillPanelHeight {
    /// Clamp a requested height into `[floor, screenHeight * maxFraction]`.
    ///
    /// The ceiling wins outright when the two bounds cross (a display shorter
    /// than `floor / maxFraction`): overflowing the screen is the failure this
    /// exists to prevent, so it is never traded away for the floor.
    public static func clamped(
        _ requested: CGFloat,
        floor: CGFloat,
        screenHeight: CGFloat,
        maxFraction: CGFloat
    ) -> CGFloat {
        let ceiling = screenHeight * maxFraction
        return min(max(requested, floor), ceiling)
    }

    /// Height to use after a screen-parameter change.
    ///
    /// Keeps whatever height the content has grown to — recomputing from the
    /// floor would shrink the board back on every resolution switch, exactly
    /// when it needs its room — but re-clamps against the NEW screen. Carrying
    /// a height grown on a large display onto a smaller one is precisely how
    /// the panel ended up taller than its own ceiling.
    public static func onScreenChange(
        currentHeight: CGFloat,
        floor: CGFloat,
        screenHeight: CGFloat,
        maxFraction: CGFloat
    ) -> CGFloat {
        clamped(currentHeight, floor: floor, screenHeight: screenHeight, maxFraction: maxFraction)
    }

    /// Height to use for a freshly measured content height.
    public static func onContentHeight(
        _ requested: CGFloat,
        floor: CGFloat,
        screenHeight: CGFloat,
        maxFraction: CGFloat
    ) -> CGFloat {
        clamped(requested, floor: floor, screenHeight: screenHeight, maxFraction: maxFraction)
    }
}
