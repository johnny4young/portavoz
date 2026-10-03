import Foundation

/// Convert an observed target centre to the owned element's public coordinate
/// API. CGRect.infinite has finite scalar members, and CGRect accessors
/// normalize negative sizes: neither is admissible observed input geometry.
func uiPointerOffset(target: CGRect, anchor: CGRect) -> CGVector? {
    for frame in [target, anchor] {
        guard !frame.isNull, !frame.isInfinite,
              frame.size.width > 0, frame.size.height > 0,
              [frame.origin.x, frame.origin.y, frame.width, frame.height,
               frame.minX, frame.minY, frame.maxX, frame.maxY, frame.midX, frame.midY].allSatisfy(\.isFinite)
        else { return nil }
    }
    let offset = CGVector(dx: target.midX - anchor.minX, dy: target.midY - anchor.minY)
    return offset.dx.isFinite && offset.dy.isFinite ? offset : nil
}
