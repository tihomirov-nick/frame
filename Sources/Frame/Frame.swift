// Frame, variant A of the glyphs: a screen frame with a solid camera bubble at its lower left corner, as in Loom. The
// bubble is also the record dot. A black gap (transparent in the menu bar) parts it from the frame, so the corner of the
// frame stays open around it. The same drawing in the app icon and the menu bar. While a recording runs, the menu bar
// shows the bubble as the square of a «Стоп» button in the same opening (`recording`); the app icon never does.
// `gap`: Glyph.iconGap or Glyph.menuGap. Box conventions and sizes: Glyph.swift.
import CoreGraphics

enum Frame {
    /// The rectangle the ink covers in the box with the app icon's line (Glyph.iconLine); the stop square lies inside
    /// it. The menu bar and the app icon fit it to their room (Glyph.swift). The menu bar's line is thicker and reaches
    /// half a unit (0.1 pt) further out on three sides, into the margin of its canvas; GlyphTests checks both.
    static let bounds = CGRect(x: 1.4, y: 4.4, width: 97.2, height: 89.6)

    static func draw(_ ctx: CGContext, recording: Bool = false, line w: CGFloat, gap: CGFloat) {
        let p = Glyph.p
        Glyph.stroke(ctx, Glyph.roundedRect(CGRect(x: 5, y: 8, width: 90, height: 64), 14), w)
        let bubble = Glyph.disc(p(29, 72), 22)
        Glyph.cut(ctx) {
            Glyph.stroke(ctx, bubble, 2 * gap)
            Glyph.fill(ctx, bubble)
        }
        // The opening is the bubble's in both states; the stop square sits in its middle, 36 units a side.
        Glyph.fill(ctx, recording ? Glyph.roundedRect(CGRect(x: 11, y: 54, width: 36, height: 36), 6.5) : bubble)
    }
}
