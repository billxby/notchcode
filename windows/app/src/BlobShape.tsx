// The floating form of the overlay: an all-convex rounded lozenge, used when
// the pill is dragged away from the top edge. (Docked at the top it renders as
// the concave NotchShape instead — a concave silhouette only reads correctly
// flush against a screen edge.)

type BlobShapeProps = {
  width: number;
  height: number;
  fill?: string;
  children?: React.ReactNode;
};

export default function BlobShape({
  width,
  height,
  fill = "#000000",
  children,
}: BlobShapeProps) {
  return (
    <div className="notch" style={{ width, height }}>
      <div
        className="blob-bg"
        style={{ background: fill, borderRadius: height / 2 }}
      />
      <div className="notch-content">{children}</div>
    </div>
  );
}
