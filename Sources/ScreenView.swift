// Draws a Screen into a 4:3 area of the window, like a CRT: the pixel layer first (in graphics modes),
// then text cells. Box-drawing and block characters are drawn as shapes so lines join up across cells.

import AppKit
import CoreText

final class ScreenView: NSView {
    var screen: Screen { didSet { lastVersion = -1; needsDisplay = true } }
    var showCursor = true
    var onKey: ((NSEvent) -> Void)?

    private var lastVersion = -1
    private var blinkOn = true
    private var timer: Timer?
    private var blinkCount = 0
    private var fontCache: (size: CGFloat, scaleX: CGFloat, font: CTFont)?
    private var glyphCache: [UInt32: (CTFont, CGGlyph)] = [:]

    init(screen: Screen) {
        self.screen = screen
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    var onFlags: ((NSEvent) -> Void)?
    /// Mouse events as text cells: (row, column, phase).
    var onMouse: ((Int, Int, MousePhase) -> Void)?
    enum MousePhase { case down, drag, up }

    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func flagsChanged(with event: NSEvent) { onFlags?(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { mouse(event, .down) }
    override func mouseDragged(with event: NSEvent) { mouse(event, .drag) }
    override func mouseUp(with event: NSEvent) { mouse(event, .up) }

    private func mouse(_ event: NSEvent, _ phase: MousePhase) {
        let p = convert(event.locationInWindow, from: nil)
        let area = displayRect()
        let s = screen
        let col = Int(((p.x - area.minX) / area.width * CGFloat(s.cols)).rounded(.down))
        let row = Int(((p.y - area.minY) / area.height * CGFloat(s.rows)).rounded(.down))
        onMouse?(row, col, phase)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Ctrl+key combinations go to the editor or program, not the menu.
        if event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command) { onKey?(event); return true }
        return super.performKeyEquivalent(with: event)
    }

    private func tick() {
        blinkCount += 1
        if blinkCount % 16 == 0 { blinkOn.toggle(); if showCursor { needsDisplay = true } }
        let v = screen.version
        if v != lastVersion { lastVersion = v; needsDisplay = true }
    }

    /// The 4:3 area the screen fills, centred in the view.
    private func displayRect() -> CGRect {
        let b = bounds
        var w = b.width, h = b.width * 3 / 4
        if h > b.height { h = b.height; w = h * 4 / 3 }
        return CGRect(x: ((b.width - w) / 2).rounded(), y: ((b.height - h) / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1))
        ctx.fill(bounds)
        let s = screen.snapshot()
        let area = displayRect()
        let cw = area.width / CGFloat(s.cols), ch = area.height / CGFloat(s.rows)
        func color(_ i: UInt8) -> CGColor {
            let c = s.palette[Int(i) % s.palette.count]
            return CGColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
        }
        func cellRect(_ r: Int, _ c: Int) -> CGRect {
            let x0 = (area.minX + CGFloat(c) * cw).rounded(), x1 = (area.minX + CGFloat(c + 1) * cw).rounded()
            let y0 = (area.minY + CGFloat(r) * ch).rounded(), y1 = (area.minY + CGFloat(r + 1) * ch).rounded()
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        if s.mode != 0 {
            drawPixels(ctx, s, area)
        } else {
            ctx.setFillColor(color(0))
            ctx.fill(area)
        }

        // Backgrounds. In graphics modes only cells with text cover the pixels.
        for r in 0..<s.rows {
            var c = 0
            while c < s.cols {
                let i = r * s.cols + c
                let bg = s.bgs[i]
                if s.mode != 0 && s.codes[i] == 32 { c += 1; continue }
                var e = c + 1
                while e < s.cols && s.bgs[r * s.cols + e] == bg && !(s.mode != 0 && s.codes[r * s.cols + e] == 32) { e += 1 }
                if bg != 0 || s.mode != 0 {
                    ctx.setFillColor(color(bg))
                    ctx.fill(cellRect(r, c).union(cellRect(r, e - 1)))
                }
                c = e
            }
        }

        // Glyphs, batched by font and colour.
        let font = self.font(cellW: cw, cellH: ch)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let baselineOffset = ((ch - (ascent + descent)) / 2 + ascent).rounded()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var batches: [String: (CTFont, CGColor, [CGGlyph], [CGPoint])] = [:]
        for r in 0..<s.rows {
            for c in 0..<s.cols {
                let i = r * s.cols + c
                let code = s.codes[i]
                if code == 32 || code == 0 || code == 255 { continue }
                let rect = cellRect(r, c)
                let fg = s.fgs[i]
                if drawShape(ctx, code: code, rect: rect, fg: color(fg), bg: color(s.bgs[i])) { continue }
                guard let (f, g) = glyph(for: code, base: font) else { continue }
                let key = "\(ObjectIdentifier(f as AnyObject).hashValue)-\(fg)"
                var b = batches[key] ?? (f, color(fg), [], [])
                b.2.append(g)
                // Glyph positions are in text space, which the flipped text matrix mirrors: negate y.
                b.3.append(CGPoint(x: rect.minX, y: -(rect.minY + baselineOffset)))
                batches[key] = b
            }
        }
        for (_, b) in batches {
            ctx.setFillColor(b.1)
            b.3.withUnsafeBufferPointer { pts in
                b.2.withUnsafeBufferPointer { gs in
                    CTFontDrawGlyphs(b.0, gs.baseAddress!, pts.baseAddress!, gs.count, ctx)
                }
            }
        }

        // Cursor: a blinking underline, in text mode.
        if showCursor && s.cursorVisible && blinkOn && s.mode == 0, s.curRow < s.rows, s.curCol < s.cols {
            let rect = cellRect(s.curRow, s.curCol)
            ctx.setFillColor(color(s.fgs[s.curRow * s.cols + s.curCol] == s.bgs[s.curRow * s.cols + s.curCol] ? 15 : s.fgs[s.curRow * s.cols + s.curCol]))
            let h = max(2, (ch / 8).rounded())
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - h - 1, width: rect.width, height: h))
        }
    }

    private func drawPixels(_ ctx: CGContext, _ s: Screen.Snapshot, _ area: CGRect) {
        var rgba = [UInt8](repeating: 255, count: s.pw * s.ph * 4)
        for i in 0..<(s.pw * s.ph) {
            let c = s.palette[Int(s.pixels[i]) % s.palette.count]
            rgba[i * 4] = c.r; rgba[i * 4 + 1] = c.g; rgba[i * 4 + 2] = c.b
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: s.pw, height: s.ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s.pw * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        // The context is flipped; flip the image back.
        ctx.translateBy(x: area.minX, y: area.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: area.width, height: area.height))
        ctx.restoreGState()
    }

    private func font(cellW: CGFloat, cellH: CGFloat) -> CTFont {
        let size = (cellH * 0.8).rounded(.down)
        let probe = CTFontCreateWithName("Menlo" as CFString, size, nil)
        var g = CGGlyph(0), ch = UniChar(77)
        CTFontGetGlyphsForCharacters(probe, &ch, &g, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(probe, .horizontal, &g, &adv, 1)
        let scaleX = adv.width > 0 ? cellW / adv.width : 1
        if let c = fontCache, c.size == size, abs(c.scaleX - scaleX) < 0.001 { return c.font }
        var m = CGAffineTransform(scaleX: scaleX, y: 1)
        let f = CTFontCreateWithName("Menlo" as CFString, size, &m)
        fontCache = (size, scaleX, f)
        glyphCache.removeAll()
        return f
    }

    private func glyph(for code: UInt32, base: CTFont) -> (CTFont, CGGlyph)? {
        if let g = glyphCache[code] { return g }
        let ch: Character = code < 256 ? cp437[Int(code)] : Character(UnicodeScalar(code) ?? "?")
        let str = String(ch) as NSString
        var units = [UniChar](repeating: 0, count: str.length)
        str.getCharacters(&units, range: NSRange(location: 0, length: str.length))
        var gs = [CGGlyph](repeating: 0, count: units.count)
        var font = base
        if !CTFontGetGlyphsForCharacters(base, &units, &gs, units.count) || gs[0] == 0 {
            font = CTFontCreateForString(base, str as CFString, CFRange(location: 0, length: str.length))
            CTFontGetGlyphsForCharacters(font, &units, &gs, units.count)
        }
        guard gs[0] != 0 else { return nil }
        glyphCache[code] = (font, gs[0])
        return (font, gs[0])
    }

    // MARK: Box drawing and blocks

    /// Arms of each box-drawing character: (up, down, left, right), 1 = single line, 2 = double.
    private static let boxArms: [Character: (Int, Int, Int, Int)] = [
        "─": (0, 0, 1, 1), "│": (1, 1, 0, 0), "┌": (0, 1, 0, 1), "┐": (0, 1, 1, 0), "└": (1, 0, 0, 1), "┘": (1, 0, 1, 0),
        "├": (1, 1, 0, 1), "┤": (1, 1, 1, 0), "┬": (0, 1, 1, 1), "┴": (1, 0, 1, 1), "┼": (1, 1, 1, 1),
        "═": (0, 0, 2, 2), "║": (2, 2, 0, 0), "╔": (0, 2, 0, 2), "╗": (0, 2, 2, 0), "╚": (2, 0, 0, 2), "╝": (2, 0, 2, 0),
        "╠": (2, 2, 0, 2), "╣": (2, 2, 2, 0), "╦": (0, 2, 2, 2), "╩": (2, 0, 2, 2), "╬": (2, 2, 2, 2),
        "╡": (1, 1, 2, 0), "╢": (2, 2, 1, 0), "╖": (0, 2, 1, 0), "╕": (0, 1, 2, 0), "╜": (2, 0, 1, 0), "╛": (1, 0, 2, 0),
        "╞": (1, 1, 0, 2), "╟": (2, 2, 0, 1), "╧": (1, 0, 2, 2), "╨": (2, 0, 1, 1), "╤": (0, 1, 2, 2), "╥": (0, 2, 1, 1),
        "╙": (2, 0, 0, 1), "╘": (1, 0, 0, 2), "╒": (0, 1, 0, 2), "╓": (0, 2, 0, 1), "╫": (2, 2, 1, 1), "╪": (1, 1, 2, 2),
    ]

    private func drawShape(_ ctx: CGContext, code: UInt32, rect r: CGRect, fg: CGColor, bg: CGColor) -> Bool {
        guard code < 256 else { return false }
        let ch = cp437[Int(code)]
        ctx.setFillColor(fg)
        switch ch {
        case "█": ctx.fill(r); return true
        case "▀": ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: (r.height / 2).rounded())); return true
        case "▄": let h = (r.height / 2).rounded(); ctx.fill(CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)); return true
        case "▌": ctx.fill(CGRect(x: r.minX, y: r.minY, width: (r.width / 2).rounded(), height: r.height)); return true
        case "▐": let w = (r.width / 2).rounded(); ctx.fill(CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height)); return true
        case "░", "▒", "▓":
            let alpha: CGFloat = ch == "░" ? 0.25 : ch == "▒" ? 0.5 : 0.75
            ctx.setFillColor(fg.copy(alpha: alpha)!)
            ctx.fill(r)
            return true
        case "■":
            let w = (r.width * 0.5).rounded(), h = (r.height * 0.36).rounded()
            ctx.fill(CGRect(x: (r.midX - w / 2).rounded(), y: (r.midY - h / 2).rounded(), width: w, height: h))
            return true
        default: break
        }
        guard let (up, down, left, right) = ScreenView.boxArms[ch] else { return false }
        let t = max(1, (r.height / 14).rounded())          // line thickness
        let g = max(t + 1, (r.width / 5).rounded())        // half the gap between double lines
        let cx = (r.midX - t / 2).rounded(), cy = (r.midY - t / 2).rounded()
        let anyVDouble = up == 2 || down == 2, anyHDouble = left == 2 || right == 2
        func h(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) { ctx.fill(CGRect(x: min(x0, x1), y: y, width: abs(x1 - x0) + t, height: t)) }
        func v(_ y0: CGFloat, _ y1: CGFloat, _ x: CGFloat) { ctx.fill(CGRect(x: x, y: min(y0, y1), width: t, height: abs(y1 - y0) + t)) }
        // Horizontal arms.
        if left == 1 { h(r.minX, anyVDouble ? cx - g : cx, cy) }
        if right == 1 { h(anyVDouble ? cx + g : cx, r.maxX - t, cy) }
        if left == 2 {
            h(r.minX, up == 2 ? cx - g : cx + g, cy - g)
            h(r.minX, down == 2 ? cx - g : cx + g, cy + g)
        }
        if right == 2 {
            h(up == 2 ? cx + g : cx - g, r.maxX - t, cy - g)
            h(down == 2 ? cx + g : cx - g, r.maxX - t, cy + g)
        }
        // Vertical arms.
        if up == 1 { v(r.minY, anyHDouble ? cy - g : cy, cx) }
        if down == 1 { v(anyHDouble ? cy + g : cy, r.maxY - t, cx) }
        if up == 2 {
            v(r.minY, left == 2 ? cy - g : cy + g, cx - g)
            v(r.minY, right == 2 ? cy - g : cy + g, cx + g)
        }
        if down == 2 {
            v(left == 2 ? cy + g : cy - g, r.maxY - t, cx - g)
            v(right == 2 ? cy + g : cy - g, r.maxY - t, cx + g)
        }
        return true
    }
}
