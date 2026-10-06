import AppKit
import SwiftUI

/// One transparent, click-through panel per display, rebuilt when displays change.
@MainActor
final class OverlayWindows {
    private let model: OverlayModel
    private var windows: [NSWindow] = []

    init(model: OverlayModel) {
        self.model = model
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height

        for screen in NSScreen.screens {
            let window = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            // Best effort only: recent macOS versions don't honor this for ScreenCaptureKit.
            // The capture code must exclude this process's windows via SCContentFilter.
            window.sharingType = .none

            let tl = ScreenGeometry.topLeftFrame(screen.frame, primaryHeight: primaryHeight)
            let inset = ScreenGeometry.safeInsets(frame: screen.frame, visible: screen.visibleFrame)
            let view = OverlayView(
                model: model,
                origin: tl.origin,
                size: tl.size,
                safe: EdgeInsets(top: inset.top, leading: inset.left, bottom: inset.bottom, trailing: inset.right),
                isPrimary: screen == primary
            )
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }
}
