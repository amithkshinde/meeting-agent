import AppKit

/// A small always-on-top window that never takes focus, so it won't interrupt typing in the call.
/// `sharingType = .none` keeps it out of screen shares and out of our own recording.
final class FloatingPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        sharingType = .none
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Places the panel at the top right of the main screen.
    func moveToTopRight() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16))
    }

    /// Resizes to the content while keeping the top edge where it is.
    func fitToContent() {
        guard let view = contentView else { return }
        let target = view.fittingSize
        guard target.width > 0, target.height > 0 else { return }
        var next = frame
        next.origin.y += next.height - target.height
        next.size = target
        setFrame(next, display: true)
    }
}
