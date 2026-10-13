import Foundation
import UlaniKit

/// The card page (牌卡, shared/CARDS.md "Drawing"; python/src/ulani_epaper/layouts.py, "Cards"):
/// the background, then each text box in order, with the message board's text rules.
public enum CardPages {
    /// Python: `render_card`. `background`: the card's photo already cut and dithered
    /// (`CardStore.background(of:strength:)`), drawn instead of its colour, so an editor that
    /// redraws on every change dithers it once; without it the card's colour fills the screen.
    public static func card(_ card: Card, background: Frame? = nil) -> PageCanvas {
        var page = PageCanvas()
        draw(&page, card, background)
        return page
    }

    static func draw(_ p: inout PageCanvas, _ card: Card, _ background: Frame?) {
        if let background {
            p.paste(background)
        } else {
            p.rect(0, 0, PageCanvas.width - 1, PageCanvas.height - 1, fill: card.background.color)
        }
        for t in card.texts { text(&p, t) }
    }

    /// One text box: bold, wrapped inside the box from its top, aligned; the outline stays inside
    /// the box too (Python: `_card_text`).
    static func text(_ p: inout PageCanvas, _ t: CardText) {
        let outline = t.outline ? PageCanvas.outlineRadius(size: t.size) : 0
        let left = pixels(t.box.x, PageCanvas.width) + outline, top = pixels(t.box.y, PageCanvas.height) + outline
        let right = pixels(t.box.x + t.box.width, PageCanvas.width) - outline
        let bottom = pixels(t.box.y + t.box.height, PageCanvas.height) - outline
        // every line break counts, so a blank line stays; blank lines at the start or end are dropped
        var paras = t.text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { PageFonts.clean(PythonText.string($0)) }
        while paras.first == "" { paras.removeFirst() }
        while paras.last == "" { paras.removeLast() }
        guard !paras.isEmpty, right > left else { return }
        let (above, below) = BoardPage.glyphExtent(t.size)
        let pitch = Double(t.size) * BoardPage.pitch
        let rows = (Double(bottom - top - above - below) / pitch).rounded(.down)
        let font = PageFont(size: t.size, bold: true)
        let lines = BoardPage.flow(paras, font, Double(right - left), max(1, Int(rows) + 1)).lines  // one line at least
        let (x, anchor): (Int, TextAnchor) = switch t.align {
        case .left: (left, .left)
        case .center: ((left + right) / 2, .centre)
        case .right: (right, .right)
        }
        for (i, line) in lines.enumerated() {
            let y = top + above + Int((Double(i) * pitch + 0.5).rounded(.down))
            p.text(line, x: Double(x), y: Double(y), size: t.size, bold: true, fill: t.color, anchor: anchor,
                   maxWidth: Double(right - left), outline: outline, outlineColour: t.outlineColor)
        }
    }

    /// A screen fraction in pixels, halves rounded up: floor(fraction * total + 0.5) (Python: `_px`).
    static func pixels(_ fraction: Double, _ total: Int) -> Int {
        Int((fraction * Double(total) + 0.5).rounded(.down))
    }
}
