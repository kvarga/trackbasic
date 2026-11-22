// The display: an 80×25 (or 40×25 / 80×30) text screen with 16 colours, plus an optional pixel layer
// for SCREEN 12 and SCREEN 13. Shared between the interpreter thread and the view, so every access
// goes through `lock`.

import Foundation

/// Code page 437: what bytes 0…255 looked like on a PC.
let cp437: [Character] = {
    let low = " ☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼"
    let high = "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "
    var t = Array(low)
    for c in 32..<127 { t.append(Character(UnicodeScalar(UInt8(c)))) }
    t.append("⌂")
    t += Array(high)
    return t
}()

/// Unicode back to CP437, so box-drawing characters typed into the editor print as themselves.
let unicodeToCP437: [Character: UInt32] = {
    var m: [Character: UInt32] = [:]
    for (i, c) in cp437.enumerated() where i >= 128 || i < 32 { m[c] = UInt32(i) }
    return m
}()

typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

let ega16: [RGB] = [
    (0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170), (170, 0, 0), (170, 0, 170), (170, 85, 0), (170, 170, 170),
    (85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255), (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255),
]

/// The VGA mode 13h default palette: the 16 EGA colours, a grey ramp, then 9 blocks of 24 hues
/// (three brightnesses × three saturations).
let vga256: [RGB] = {
    var p = ega16
    let greys: [UInt8] = [0, 5, 8, 11, 14, 17, 20, 24, 28, 32, 36, 40, 45, 50, 56, 63]
    p += greys.map { g in let v = UInt8(Int(g) * 255 / 63); return (v, v, v) }
    for (hi, lo) in [(63, 0), (28, 0), (16, 0)] {
        for sat in 0..<3 {
            let mid = lo + (hi - lo) * [0, 2, 3][sat] / 4
            let base = sat == 0 ? lo : mid
            // 24 hues around the wheel: blue → magenta → red → yellow → green → cyan → blue.
            var hues: [(Int, Int, Int)] = []
            let ramp = [base, base + (hi - base) / 4, base + (hi - base) / 2, base + 3 * (hi - base) / 4]
            for v in ramp { hues.append((v, base, hi)) }
            for v in ramp.reversed() { hues.append((hi, base, v)) }
            for v in ramp { hues.append((hi, v, base)) }
            for v in ramp.reversed() { hues.append((v, hi, base)) }
            for v in ramp { hues.append((base, hi, v)) }
            for v in ramp.reversed() { hues.append((base, v, hi)) }
            p += hues.map { (UInt8($0.0 * 255 / 63), UInt8($0.1 * 255 / 63), UInt8($0.2 * 255 / 63)) }
        }
    }
    while p.count < 256 { p.append((0, 0, 0)) }
    return Array(p.prefix(256))
}()

final class Screen {
    let lock = NSLock()

    private(set) var cols = 80
    private(set) var rows = 25
    var codes: [UInt32]
    var fgs: [UInt8]
    var bgs: [UInt8]
    var curRow = 0, curCol = 0
    var fg: UInt8 = 7, bg: UInt8 = 0
    var cursorVisible = true
    /// The rows PRINT scrolls (VIEW PRINT); 0-based, inclusive.
    var viewTop = 0, viewBottom = 24

    /// 0 = text, 12 = 640×480×16, 13 = 320×200×256.
    private(set) var mode = 0
    private(set) var pw = 0, ph = 0
    var pixels: [UInt8] = []
    var palette: [RGB] = ega16
    /// Last point drawn, for relative graphics (LINE -(x, y), CIRCLE STEP).
    var lastX = 0.0, lastY = 0.0

    /// Bumped on every change, so the view knows when to redraw.
    private(set) var version = 0

    init() {
        codes = Array(repeating: 32, count: 80 * 25)
        fgs = Array(repeating: 7, count: 80 * 25)
        bgs = Array(repeating: 0, count: 80 * 25)
    }

    func touch() { version &+= 1 }

    // MARK: Mode

    func setMode(_ m: Int) throws {
        switch m {
        case 0: resizeText(80, 25); pixels = []; pw = 0; ph = 0; palette = ega16
        case 12: resizeText(80, 30); pw = 640; ph = 480; palette = ega16
        case 13: resizeText(40, 25); pw = 320; ph = 200; palette = vga256
        default: throw BasicError.illegalFunctionCall("SCREEN \(m) isn't supported (use 0, 12 or 13)")
        }
        mode = m
        pixels = Array(repeating: 0, count: pw * ph)
        fg = m == 0 ? 7 : 15; bg = 0
        lastX = Double(pw / 2); lastY = Double(ph / 2)
        touch()
    }

    private func resizeText(_ c: Int, _ r: Int) {
        cols = c; rows = r
        codes = Array(repeating: 32, count: c * r)
        fgs = Array(repeating: 7, count: c * r)
        bgs = Array(repeating: 0, count: c * r)
        curRow = 0; curCol = 0
        viewTop = 0; viewBottom = r - 1
    }

    // MARK: Text

    func cls() {
        let top = viewTop * cols, end = (viewBottom + 1) * cols
        for i in top..<end { codes[i] = 32; fgs[i] = fg; bgs[i] = bg }
        if mode != 0 {
            for i in pixels.indices { pixels[i] = bg }
        }
        curRow = viewTop; curCol = 0
        touch()
    }

    func put(_ row: Int, _ col: Int, _ code: UInt32, fg f: UInt8, bg b: UInt8) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        let i = row * cols + col
        codes[i] = code; fgs[i] = f; bgs[i] = b
    }

    func text(_ row: Int, _ col: Int, _ s: String, fg f: UInt8, bg b: UInt8) {
        var c = col
        for ch in s { put(row, c, Screen.code(ch), fg: f, bg: b); c += 1 }
    }

    static func code(_ ch: Character) -> UInt32 {
        if let s = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, s.value < 256 { return s.value }
        return unicodeToCP437[ch] ?? (ch.unicodeScalars.first?.value ?? 63)
    }

    func newline() {
        curCol = 0
        curRow += 1
        if curRow > viewBottom { scroll(); curRow = viewBottom }
    }

    private func scroll() {
        for r in viewTop..<viewBottom {
            for c in 0..<cols {
                let d = r * cols + c, s = (r + 1) * cols + c
                codes[d] = codes[s]; fgs[d] = fgs[s]; bgs[d] = bgs[s]
            }
        }
        for c in 0..<cols { put(viewBottom, c, 32, fg: fg, bg: bg) }
        if mode != 0 {
            // Graphics scroll by one text row of pixels.
            let rowH = ph / rows
            let shift = rowH * pw
            let top = viewTop * rowH * pw, bottom = (viewBottom + 1) * rowH * pw
            if bottom - shift > top {
                for i in top..<(bottom - shift) { pixels[i] = pixels[i + shift] }
            }
            for i in max(top, bottom - shift)..<bottom { pixels[i] = bg }
        }
    }

    /// Writes characters at the cursor, wrapping and scrolling as PRINT does. "\n" moves to a new line.
    func write(_ s: String) {
        for ch in s.unicodeScalars {
            if ch == "\n" { newline(); continue }
            if ch == "\r" { curCol = 0; continue }
            if curCol >= cols { newline() }
            put(curRow, curCol, ch.value < 256 ? ch.value : Screen.code(Character(ch)), fg: fg, bg: bg)
            curCol += 1
        }
        touch()
    }

    // MARK: Pixels

    func pset(_ x: Int, _ y: Int, _ c: UInt8) {
        guard x >= 0, y >= 0, x < pw, y < ph else { return }
        pixels[y * pw + x] = mode == 12 ? c & 15 : c
    }

    func point(_ x: Int, _ y: Int) -> Int {
        guard x >= 0, y >= 0, x < pw, y < ph else { return -1 }
        return Int(pixels[y * pw + x])
    }

    func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: UInt8) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            pset(x, y, c)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: UInt8, fill: Bool) {
        if fill {
            for y in min(y0, y1)...max(y0, y1) { for x in min(x0, x1)...max(x0, x1) { pset(x, y, c) } }
        } else {
            line(x0, y0, x1, y0, c); line(x1, y0, x1, y1, c); line(x1, y1, x0, y1, c); line(x0, y1, x0, y0, c)
        }
    }

    func circle(_ cx: Double, _ cy: Double, _ r: Double, _ c: UInt8, aspect: Double) {
        // Pixels on these screens aren't square; QBasic's default aspect makes circles look round on a 4:3 monitor.
        let rx = aspect <= 1 ? r : r / aspect
        let ry = aspect <= 1 ? r * aspect : r
        let steps = max(16, Int(max(rx, ry) * 8))
        var px = Int((cx + rx).rounded()), py = Int(cy.rounded())
        for i in 1...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let x = Int((cx + rx * cos(a)).rounded()), y = Int((cy - ry * sin(a)).rounded())
            line(px, py, x, y, c)
            px = x; py = y
        }
    }

    func paint(_ x: Int, _ y: Int, _ c: UInt8, border: UInt8) {
        guard x >= 0, y >= 0, x < pw, y < ph else { return }
        var stack = [(x, y)]
        var seen = [Bool](repeating: false, count: pw * ph)
        while let (px, py) = stack.popLast() {
            guard px >= 0, py >= 0, px < pw, py < ph else { continue }
            let i = py * pw + px
            if seen[i] || pixels[i] == border { continue }
            seen[i] = true
            pixels[i] = c
            stack.append((px + 1, py)); stack.append((px - 1, py)); stack.append((px, py + 1)); stack.append((px, py - 1))
        }
    }

    // MARK: Snapshot for drawing

    struct Snapshot {
        var cols: Int, rows: Int
        var codes: [UInt32], fgs: [UInt8], bgs: [UInt8]
        var curRow: Int, curCol: Int, cursorVisible: Bool
        var mode: Int, pw: Int, ph: Int
        var pixels: [UInt8]
        var palette: [RGB]
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(cols: cols, rows: rows, codes: codes, fgs: fgs, bgs: bgs, curRow: curRow, curCol: curCol,
                        cursorVisible: cursorVisible, mode: mode, pw: pw, ph: ph, pixels: pixels, palette: palette)
    }
}
