import CoreGraphics

/// Small math of the edit: easing curves and straight lines between values.
public enum Ease {
    public static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// 0 → 0 and 1 → 1, flat at both ends.
    public static func smooth(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * (3 - 2 * t)
    }

    /// Flatter still: no speed and no acceleration at either end.
    public static func smoother(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    public static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
    }
}
