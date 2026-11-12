import Foundation

/// The Lanczos-2 filter as the renderer's shaders use it: a table of tap
/// weights per sub-pixel phase, built here and uploaded once.
///
/// A table rather than `sin` in the shader because the table is the one copy
/// of the filter — the tests check it, and the GPU reads exactly what they
/// checked. Sixty-four phases are far below what a picture can show (the
/// phase error is under 1/126 of a source pixel).
///
/// Four taps per axis: Lanczos-2's support is ±2 source pixels, so the
/// samples at `base - 1 … base + 2` around a position `base + f` carry every
/// non-zero weight.
public enum LanczosKernel {
    /// Lobes either side of the centre.
    public static let radius: Double = 2
    /// Phases in the table. Index `i` is the phase `i / (phases - 1)`, so the
    /// first entry is "exactly on a source pixel" and the last "exactly on
    /// the next one".
    public static let phases = 64

    /// `sinc(x) · sinc(x / 2)` for |x| < 2, else 0, with the normalised sinc.
    public static func weight(_ x: Double) -> Double {
        let distance = abs(x)
        guard distance < radius else { return 0 }
        guard distance > 1e-9 else { return 1 }
        let px = Double.pi * distance
        return radius * sin(px) * sin(px / radius) / (px * px)
    }

    /// The four weights for a sample `phase` (0…1) past the source pixel
    /// `base`, for the taps `base - 1, base, base + 1, base + 2`, normalised
    /// to sum to one — so a flat picture stays exactly flat.
    public static func taps(phase: Double) -> SIMD4<Float> {
        let raw = SIMD4<Double>(
            weight(1 + phase),
            weight(phase),
            weight(1 - phase),
            weight(2 - phase)
        )
        let sum = raw.sum()
        let normalised = sum != 0 ? raw / sum : SIMD4(0, 1, 0, 0)
        return SIMD4<Float>(normalised)
    }

    /// The table the shaders read: `phases` entries of four weights.
    public static let table: [SIMD4<Float>] = (0..<phases).map {
        taps(phase: Double($0) / Double(phases - 1))
    }
}
