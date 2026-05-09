// Inspired by MrKai77/DynamicNotchKit (MIT). See CREDITS.md.
//
// A `Shape` is SwiftUI's protocol for "describe a 2D path I can fill or stroke."
// We hand-draw the notch silhouette: flat top edge, two outer corners that
// curve INWARD (concave), and two inner bottom corners that curve in the usual
// (convex) direction. The result reads as one seamless extension of the real
// hardware notch.
//
// Geometry, top-down (Apple's notch is ~32pt tall, ~200pt wide):
//
//     ┌─────────────────────────┐  ← top edge sits flush with screen top
//     │                         │
//     ╲                         ╱  ← outer corners (concave, topRadius)
//      ╲_______________________╱   ← bottom edge
//        ↑                   ↑
//        bottom corners (convex, bottomRadius)

import SwiftUI

struct NotchShape: Shape {
    /// Radius at the two TOP corners (where the notch meets the screen edge).
    /// Concave — the path curves outward away from the notch interior.
    var topRadius: CGFloat = 8
    /// Radius at the two BOTTOM corners (where the notch ends and air begins).
    /// Convex — standard rounded-rectangle behavior.
    var bottomRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tr = topRadius
        let br = bottomRadius

        // Start at the top-left, just past the corner radius.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left concave corner: arc that bulges OUT of the notch interior.
        // We use addQuadCurve with a control point at (minX + tr, minY) to fake
        // the concave curve cheaply. Quadratic is good enough at this scale.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )

        // Down the left side to where the bottom-left convex curve begins.
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))

        // Bottom-left convex corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )

        // Across the bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))

        // Bottom-right convex corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )

        // Up the right side.
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))

        // Top-right concave corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

#Preview {
    NotchShape()
        .fill(.black)
        .frame(width: 200, height: 32)
        .padding()
        .background(.gray)
}
