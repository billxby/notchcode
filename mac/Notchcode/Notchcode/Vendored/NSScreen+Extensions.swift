// Vendored from MrKai77/DynamicNotchKit (MIT). See CREDITS.md.
//
// What this file does: extends NSScreen — the AppKit type that represents a
// physical display — with helpers to compute where the notch lives in screen
// coordinates. Apple exposes the notch indirectly via three properties:
//
//   - safeAreaInsets.top         → the notch's height
//   - auxiliaryTopLeftArea       → the menubar strip to the LEFT of the notch
//   - auxiliaryTopRightArea      → the menubar strip to the RIGHT of the notch
//
// On a non-notch Mac, the auxiliary areas are nil. We return nil from `notchSize`
// in that case so callers can decide whether to render a fake notch later.

import AppKit

extension NSScreen {
    /// True only on physical-notch MacBooks (M1 Pro/Max '21 and later).
    var hasNotch: Bool {
        auxiliaryTopLeftArea?.width != nil && auxiliaryTopRightArea?.width != nil
    }

    /// Width × height of the notch cutout in points. nil on non-notch Macs.
    var notchSize: NSSize? {
        guard
            let leftPad = auxiliaryTopLeftArea?.width,
            let rightPad = auxiliaryTopRightArea?.width
        else { return nil }
        // frame.width is the full display width; subtract the two side strips
        // to get the gap between them — that gap IS the notch's width.
        return NSSize(
            width: frame.width - leftPad - rightPad,
            height: safeAreaInsets.top
        )
    }

    /// Notch position in *global* screen coordinates (origin = bottom-left of
    /// the primary display, y grows upward — AppKit convention, not UIKit).
    var notchFrame: NSRect? {
        guard let size = notchSize else { return nil }
        return NSRect(
            x: frame.midX - (size.width / 2),       // horizontally centered
            y: frame.maxY - size.height,            // top edge of the screen
            width: size.width,
            height: size.height
        )
    }

    /// Height of the menu bar above the visibleFrame. Useful when you want to
    /// align UI just below the notch on non-notch Macs.
    var menubarHeight: CGFloat { frame.maxY - visibleFrame.maxY }
}
