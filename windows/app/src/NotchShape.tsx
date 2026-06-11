// The virtual-notch silhouette, ported 1:1 from the macOS `NotchShape.swift`
// (mac/Notchcode/Notchcode/Vendored/NotchShape.swift). See notchcode-plan.md
// §11.2 — on a WebView stack the two-radius shape is just an SVG path, no
// `SetWindowRgn` / Direct2D needed.
//
// Geometry, top-down (flush top edge against the screen):
//
//     ┌─────────────────────────┐  ← top edge, sits at y=0
//     ╲                         ╱   ← outer corners curve INWARD (concave, topRadius)
//      ╲_______________________╱    ← bottom edge
//        ↑                   ↑
//        bottom corners curve the usual way (convex, bottomRadius)

type NotchShapeProps = {
  width: number;
  height: number;
  /** Concave corners where the pill meets the top screen edge. */
  topRadius?: number;
  /** Convex corners where the pill ends and air begins. */
  bottomRadius?: number;
  /** Fill color of the opaque pill body. */
  fill?: string;
  children?: React.ReactNode;
};

/** Build the SVG path string — the direct analog of Swift's `path(in:)`. */
function notchPath(w: number, h: number, tr: number, br: number): string {
  return [
    `M 0 0`, // top-left, flush with the screen edge
    `Q ${tr} 0 ${tr} ${tr}`, // top-left concave corner
    `L ${tr} ${h - br}`, // down the left side
    `Q ${tr} ${h} ${tr + br} ${h}`, // bottom-left convex corner
    `L ${w - tr - br} ${h}`, // across the bottom
    `Q ${w - tr} ${h} ${w - tr} ${h - br}`, // bottom-right convex corner
    `L ${w - tr} ${tr}`, // up the right side
    `Q ${w - tr} 0 ${w} 0`, // top-right concave corner
    `Z`,
  ].join(" ");
}

export default function NotchShape({
  width,
  height,
  topRadius = 8,
  bottomRadius = 10,
  fill = "#000000",
  children,
}: NotchShapeProps) {
  const d = notchPath(width, height, topRadius, bottomRadius);

  return (
    <div className="notch" style={{ width, height }}>
      <svg
        className="notch-bg"
        width={width}
        height={height}
        viewBox={`0 0 ${width} ${height}`}
        aria-hidden="true"
      >
        <path d={d} fill={fill} />
      </svg>
      <div className="notch-content">{children}</div>
    </div>
  );
}
