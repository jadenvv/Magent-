import AppKit

enum ScreenGeometry {
    /// Converts an AppKit global frame (bottom-left origin) into the top-left global space
    /// used by CGEvent/AX, given the height of the primary display.
    static func topLeftFrame(_ appKitFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: appKitFrame.minX,
            y: primaryHeight - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }

    /// Insets of the menu bar / Dock relative to the full screen frame, in top-left terms.
    static func safeInsets(frame: CGRect, visible: CGRect) -> NSEdgeInsets {
        NSEdgeInsets(
            top: frame.maxY - visible.maxY,
            left: visible.minX - frame.minX,
            bottom: visible.minY - frame.minY,
            right: frame.maxX - visible.maxX
        )
    }
}
