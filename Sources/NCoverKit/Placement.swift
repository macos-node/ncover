import Foundation

/// Snap threshold, canvas pixels.
public let SNAP: Double = 10.0

/// Where the source sits on the square canvas.
public struct Placement: Equatable, Sendable {
    /// Top-left of the scaled image, in canvas coordinates.
    public var dx: Double
    public var dy: Double
    public var scale: Double

    public init(dx: Double, dy: Double, scale: Double) {
        self.dx = dx; self.dy = dy; self.scale = scale
    }

    /// Scale to COVER the canvas, centred — the sane opening position: no gaps,
    /// nothing arbitrary cropped off one side.
    public static func cover(sw: Int, sh: Int, canvas c: Int) -> Placement {
        let scale = max(Double(c) / Double(sw), Double(c) / Double(sh))
        return Placement(dx: (Double(c) - Double(sw) * scale) / 2,
                         dy: (Double(c) - Double(sh) * scale) / 2,
                         scale: scale)
    }

    /// Whole image inside the canvas, centred.
    public static func fit(sw: Int, sh: Int, canvas c: Int) -> Placement {
        let scale = min(Double(c) / Double(sw), Double(c) / Double(sh))
        return Placement(dx: (Double(c) - Double(sw) * scale) / 2,
                         dy: (Double(c) - Double(sh) * scale) / 2,
                         scale: scale)
    }

    /// Rescale a framing from one canvas to another. Changing the output size
    /// must not re-crop what you already framed — the picture stays where you
    /// put it, the square around it just gets bigger.
    public func rescaled(from: Int, to: Int) -> Placement {
        let k = Double(to) / Double(from)
        return Placement(dx: dx * k, dy: dy * k, scale: scale * k)
    }

    public func w(_ sw: Int) -> Double { Double(sw) * scale }
    public func h(_ sh: Int) -> Double { Double(sh) * scale }
}

public struct SnapResult: Equatable, Sendable {
    public let placement: Placement
    public let snappedX: Bool
    public let snappedY: Bool
}

/// Snap to the canvas's centre and edges. Each axis is considered
/// **independently** — you can be snapped horizontally while still free
/// vertically, which is what makes it feel like a guide rather than a magnet.
///
/// Reports which guides fired so the view can SHOW why the image stopped
/// moving. A snap you cannot see is just a bug.
public func snap(_ p: Placement, sw: Int, sh: Int, canvas: Int) -> SnapResult {
    var p = p
    let c = Double(canvas)
    let iw = p.w(sw), ih = p.h(sh)

    var sx = false
    for target in [0.0, c - iw, (c - iw) / 2] where abs(p.dx - target) <= SNAP {
        p.dx = target; sx = true; break
    }
    var sy = false
    for target in [0.0, c - ih, (c - ih) / 2] where abs(p.dy - target) <= SNAP {
        p.dy = target; sy = true; break
    }
    return SnapResult(placement: p, snappedX: sx, snappedY: sy)
}

/// Resolve a drag in progress: the placement as it stood when the gesture began,
/// plus the gesture's **total** translation in view points.
///
/// The anchor is the whole point. Accumulating per-frame deltas onto the
/// *snapped* placement looks equivalent and is not: inside a snap zone every
/// frame is pulled back to the target and the motion in between is discarded, so
/// a slow drag can never escape the centre guide while a fast flick sails
/// straight through. Snapping is for display; the anchor is the truth.
public func resolveDrag(anchor: Placement,
                        translationX: Double, translationY: Double,
                        viewScale: Double,
                        sw: Int, sh: Int, canvas: Int) -> SnapResult {
    guard viewScale > 0 else {
        return SnapResult(placement: anchor, snappedX: false, snappedY: false)
    }
    // View points -> canvas pixels. Without dividing by the view scale the image
    // would race ahead of (or lag) the cursor.
    let want = Placement(dx: anchor.dx + translationX / viewScale,
                         dy: anchor.dy + translationY / viewScale,
                         scale: anchor.scale)
    return snap(want, sw: sw, sh: sh, canvas: canvas)
}
