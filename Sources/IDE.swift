// The blue-screen editor: edit a program, press F5 to run it, F4 to look at the output screen.

import AppKit

final class IDE {
    let view: ScreenView
    let editorScreen = Screen()
    let outputScreen = Screen()
    weak var window: NSWindow?

    private(set) var lines: [String] = [""]
    private var cx = 0, cy = 0          // cursor in the document
    private var top = 0, left = 0       // scroll
    private var insertMode = true
    private(set) var fileURL: URL?
    private(set) var dirty = false

    private enum Mode { case editing, running, finished, viewingOutput, dialog(String), help(Int) }
    private var mode = Mode.editing

    private let keys = KeyQueue()
    private var interpreter: Interpreter?

    // Layout (80×25): menu bar, frame top, 21 text rows, frame bottom, status bar.
    private let editTop = 2, editRows = 21, editCols = 78

    // Colours: QBasic's editor is grey on blue, with a grey menu bar and a cyan status bar.
    private let textFg: UInt8 = 7, textBg: UInt8 = 1

    init() {
        view = ScreenView(screen: editorScreen)
        view.onKey = { [weak self] e in self?.key(e) }
        render()
    }

    // MARK: Files

    var displayName: String { fileURL?.lastPathComponent ?? "Untitled" }

    func load(text: String, url: URL?) {
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "    ") }
        while lines.count > 1 && lines.last == "" { lines.removeLast() }
        if lines.isEmpty { lines = [""] }
        fileURL = url
        cx = 0; cy = 0; top = 0; left = 0
        dirty = false
        mode = .editing
        render()
        updateTitle()
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    func saved(to url: URL) { fileURL = url; dirty = false; updateTitle(); render() }

    func newProgram() { load(text: "", url: nil) }

    private func updateTitle() {
        window?.title = "TrackBASIC — " + displayName + (dirty ? " •" : "")
        window?.isDocumentEdited = dirty
    }

    func paste(_ s: String) {
        guard case .editing = mode else {
            if case .running = mode { for ch in s { keys.push(ch == "\n" ? "\r" : String(ch)) } }
            return
        }
        tidy(cy)
        let parts = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        let line = padded(cy)
        let head = String(line.prefix(cx)), tail = String(line.dropFirst(cx))
        if parts.count == 1 {
            lines[cy] = head + parts[0] + tail
            cx += parts[0].count
        } else {
            var newLines = [head + parts[0]]
            newLines += parts[1..<(parts.count - 1)]
            newLines.append(parts.last! + tail)
            lines.replaceSubrange(cy...cy, with: newLines)
            cy += parts.count - 1
            cx = parts.last!.count
            for i in (cy - parts.count + 1)...cy { tidy(i) }
        }
        changed()
    }

    // MARK: Running

    func run() {
        switch mode {
        case .editing, .viewingOutput, .finished: break
        default: return
        }
        tidy(cy)
        let program: Program
        do {
            program = try Parser.compile(lines)
        } catch let e as ParseError {
            showError(e.message, line: e.line)
            return
        } catch {
            showError("\(error)", line: nil)
            return
        }
        outputScreen.lock.lock()
        if outputScreen.mode != 0 { try? outputScreen.setMode(0) }
        outputScreen.fg = 7; outputScreen.bg = 0
        outputScreen.viewTop = 0; outputScreen.viewBottom = outputScreen.rows - 1
        outputScreen.cursorVisible = true
        outputScreen.touch()
        outputScreen.lock.unlock()
        keys.clear()
        let interp = Interpreter(program: program, screen: outputScreen, keys: keys)
        interpreter = interp
        mode = .running
        view.screen = outputScreen
        view.showCursor = true
        let thread = Thread { [weak self] in
            var failure: RunError?
            do { try interp.run() } catch let e as RunError { failure = e } catch {}
            DispatchQueue.main.async { self?.finished(failure) }
        }
        thread.stackSize = 64 << 20   // deep recursion in user FUNCTIONs
        thread.start()
    }

    func stop() { interpreter?.stopRequested = true }

    var isRunning: Bool { if case .running = mode { return true }; return false }

    private func finished(_ failure: RunError?) {
        interpreter = nil
        if let failure {
            view.screen = editorScreen
            showError(failure.message, line: failure.line)
            return
        }
        mode = .finished
        outputScreen.lock.lock()
        let msg = "Press any key to continue"
        let row = outputScreen.rows - 1
        for c in 0..<outputScreen.cols { outputScreen.put(row, c, 32, fg: 15, bg: 0) }
        outputScreen.text(row, 0, msg, fg: 15, bg: 0)
        outputScreen.curRow = row; outputScreen.curCol = msg.count
        outputScreen.touch()
        outputScreen.lock.unlock()
        view.showCursor = false
    }

    func toggleOutput() {
        switch mode {
        case .editing: mode = .viewingOutput; view.screen = outputScreen; view.showCursor = false
        case .viewingOutput, .finished: backToEditor()
        default: break
        }
    }

    private func backToEditor() {
        mode = .editing
        view.screen = editorScreen
        view.showCursor = true
        render()
    }

    private func showError(_ message: String, line: Int?) {
        if let line, line < lines.count { cy = line; cx = 0; scrollToCursor() }
        mode = .dialog(message)
        view.screen = editorScreen
        render()
    }

    // MARK: Keys

    /// Turns a key press into what INKEY$ would return on a PC: printable text, or CHR$(0) + a scan code.
    static func pcKey(_ e: NSEvent) -> String? {
        guard let chars = e.charactersIgnoringModifiers, let first = chars.unicodeScalars.first else { return nil }
        let ext: (UInt8) -> String = { "\u{0}" + String(UnicodeScalar($0)) }
        switch Int(first.value) {
        case NSUpArrowFunctionKey: return ext(72)
        case NSDownArrowFunctionKey: return ext(80)
        case NSLeftArrowFunctionKey: return ext(75)
        case NSRightArrowFunctionKey: return ext(77)
        case NSHomeFunctionKey: return ext(71)
        case NSEndFunctionKey: return ext(79)
        case NSPageUpFunctionKey: return ext(73)
        case NSPageDownFunctionKey: return ext(81)
        case NSInsertFunctionKey: return ext(82)
        case NSDeleteFunctionKey: return ext(83)
        case NSF1FunctionKey...NSF10FunctionKey: return ext(UInt8(59 + Int(first.value) - NSF1FunctionKey))
        case 0x7F: return "\u{8}"
        case 0x0D, 0x03: return "\r"
        case 0x1B: return "\u{1B}"
        case 0x09: return "\t"
        default: break
        }
        if e.modifierFlags.contains(.control), let c = chars.uppercased().unicodeScalars.first, c.value >= 64, c.value < 96 {
            return String(UnicodeScalar(UInt8(c.value - 64)))
        }
        guard let typed = e.characters, !typed.isEmpty else { return nil }
        // Map typed Unicode (é, £, box drawing) back to code page 437 where it exists.
        var out = ""
        for ch in typed {
            let code = Screen.code(ch)
            out.unicodeScalars.append(UnicodeScalar(code < 256 ? code : 63)!)
        }
        return out
    }

    private func key(_ e: NSEvent) {
        let ctrl = e.modifierFlags.contains(.control)
        let lower = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let fkey = e.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) } ?? 0
        switch mode {
        case .running:
            if ctrl && (lower == "c" || fkey == NSPauseFunctionKey) || fkey == NSBreakFunctionKey { stop(); return }
            if let k = IDE.pcKey(e) { keys.push(k) }
        case .finished, .viewingOutput:
            backToEditor()
        case .dialog:
            mode = .editing
            render()
        case .help(let page):
            if fkey == NSPageDownFunctionKey || fkey == NSDownArrowFunctionKey || lower == " " { mode = .help(min(page + 1, IDE.help.count - 1)); render() }
            else if fkey == NSPageUpFunctionKey || fkey == NSUpArrowFunctionKey { mode = .help(max(page - 1, 0)); render() }
            else { mode = .editing; render() }
        case .editing:
            editKey(e, ctrl: ctrl, lower: lower, fkey: fkey)
        }
    }

    private func editKey(_ e: NSEvent, ctrl: Bool, lower: String, fkey: Int) {
        let shift = e.modifierFlags.contains(.shift)
        switch fkey {
        case NSF5FunctionKey: run(); return
        case NSF4FunctionKey: toggleOutput(); return
        case NSF1FunctionKey: mode = .help(0); render(); return
        case NSF9FunctionKey: cycleSound(); return
        case NSUpArrowFunctionKey: moveTo(cy - 1, cx); return
        case NSDownArrowFunctionKey: moveTo(cy + 1, cx); return
        case NSLeftArrowFunctionKey:
            if ctrl { wordLeft() } else if cx > 0 { cx -= 1 } else if cy > 0 { moveTo(cy - 1, Int.max); return }
            render(); return
        case NSRightArrowFunctionKey:
            if ctrl { wordRight() } else { cx = min(cx + 1, 255) }
            render(); return
        case NSHomeFunctionKey:
            if ctrl { moveTo(0, 0); return }
            let indent = lines[cy].prefix { $0 == " " }.count
            cx = cx == indent ? 0 : indent; render(); return
        case NSEndFunctionKey:
            if ctrl { moveTo(lines.count - 1, Int.max); return }
            cx = lines[cy].count; render(); return
        case NSPageUpFunctionKey: top = max(0, top - editRows); moveTo(cy - editRows, cx); return
        case NSPageDownFunctionKey: top = min(max(0, lines.count - 1), top + editRows); moveTo(cy + editRows, cx); return
        case NSInsertFunctionKey: insertMode.toggle(); render(); return
        case NSDeleteFunctionKey: deleteForward(); return
        default: break
        }
        if ctrl && lower == "y" {   // delete the line, as QBasic does
            lines.remove(at: cy)
            if lines.isEmpty { lines = [""] }
            cy = min(cy, lines.count - 1); cx = 0
            changed(); return
        }
        if ctrl { return }
        guard let chars = e.characters, let first = chars.unicodeScalars.first else { return }
        switch first.value {
        case 0x0D, 0x03:   // Return: split the line, keeping its indent
            tidy(cy)
            let line = padded(cy)
            let indent = String(lines[cy].prefix { $0 == " " })
            let head = String(line.prefix(cx)), tail = String(line.dropFirst(cx))
            lines[cy] = rtrim(head)
            let keepIndent = cx >= indent.count ? indent : String(indent.prefix(cx))
            lines.insert(keepIndent + tail.drop { $0 == " " && cx >= indent.count }, at: cy + 1)
            cy += 1; cx = keepIndent.count
            changed()
        case 0x7F:   // Backspace
            if cx > 0 {
                let line = padded(cy)
                if cx <= lines[cy].count {
                    var a = Array(line); a.remove(at: cx - 1); lines[cy] = String(a)
                }
                cx -= 1
            } else if cy > 0 {
                tidy(cy)
                let prev = lines[cy - 1]
                lines[cy - 1] = prev + lines[cy]
                lines.remove(at: cy)
                cy -= 1; cx = prev.count
            }
            changed()
        case 0x09:   // Tab
            let n = shift ? 0 : 4 - cx % 4
            insert(String(repeating: " ", count: n))
        case 0x1B: return
        default:
            let s = String(chars.filter { !$0.isASCII || $0.asciiValue! >= 32 })
            if !s.isEmpty { insert(s) }
        }
    }

    // MARK: Editing

    private func padded(_ row: Int) -> String {
        let l = lines[row]
        return l.count >= cx ? l : l + String(repeating: " ", count: cx - l.count)
    }

    private func rtrim(_ s: String) -> String {
        var t = s
        while t.hasSuffix(" ") { t.removeLast() }
        return t
    }

    private func insert(_ s: String) {
        var a = Array(padded(cy))
        for ch in s {
            if !insertMode && cx < a.count { a[cx] = ch } else { a.insert(ch, at: cx) }
            cx += 1
        }
        lines[cy] = String(a)
        changed()
    }

    private func deleteForward() {
        let a = Array(padded(cy))
        if cx < lines[cy].count {
            var b = a; b.remove(at: cx); lines[cy] = String(b)
        } else if cy + 1 < lines.count {
            lines[cy] = String(a) + lines[cy + 1].drop { $0 == " " && !a.isEmpty }
            lines.remove(at: cy + 1)
        }
        changed()
    }

    private func wordLeft() {
        let a = Array(lines[cy])
        var i = min(cx, a.count)
        while i > 0 && !(a[i - 1].isLetter || a[i - 1].isNumber) { i -= 1 }
        while i > 0 && (a[i - 1].isLetter || a[i - 1].isNumber) { i -= 1 }
        cx = i
    }

    private func wordRight() {
        let a = Array(lines[cy])
        var i = cx
        while i < a.count && (a[i].isLetter || a[i].isNumber) { i += 1 }
        while i < a.count && !(a[i].isLetter || a[i].isNumber) { i += 1 }
        cx = i
    }

    private func moveTo(_ row: Int, _ col: Int) {
        let r = max(0, min(lines.count - 1, row))
        if r != cy { tidy(cy) }
        cy = r
        cx = col == Int.max ? lines[cy].count : max(0, col)
        render()
    }

    /// When leaving a line: upper-case its keywords and drop trailing spaces.
    private func tidy(_ row: Int) {
        guard row < lines.count else { return }
        let t = rtrim(tidyLine(lines[row]))
        if t != lines[row] { lines[row] = t; dirty = true; updateTitle() }
    }

    private func changed() {
        if !dirty { dirty = true; updateTitle() }
        render()
    }

    private func scrollToCursor() {
        if cy < top { top = cy }
        if cy >= top + editRows { top = cy - editRows + 1 }
        if cx < left { left = cx }
        if cx >= left + editCols { left = cx - editCols + 1 }
    }

    func cycleSound() {
        let all = SoundOutput.allCases
        var next = all[(all.firstIndex(of: Speaker.shared.output)! + 1) % all.count]
        if next == .trackpad && !Speaker.shared.motor.available { next = all[(all.firstIndex(of: next)! + 1) % all.count] }
        Speaker.shared.output = next
        render()
    }

    func refresh() { render() }

    // MARK: Drawing

    private func render() {
        scrollToCursor()
        let s = editorScreen
        s.lock.lock(); defer { s.lock.unlock() }

        // Menu bar.
        for c in 0..<80 { s.put(0, c, 32, fg: 0, bg: 7) }
        s.text(0, 2, "File  Edit  Run  Sound", fg: 0, bg: 7)
        s.text(0, 73, "Help", fg: 0, bg: 7)
        for (col, len) in [(2, 1), (8, 1), (14, 1), (19, 1), (73, 1)] { s.put(0, col, s.codes[col], fg: 15, bg: 7); _ = len }

        // Frame with the file name.
        let title = " " + displayName + " "
        for c in 0..<80 { s.put(1, c, Screen.code("─"), fg: textFg, bg: textBg); s.put(23, c, Screen.code("─"), fg: textFg, bg: textBg) }
        s.put(1, 0, Screen.code("┌"), fg: textFg, bg: textBg); s.put(1, 79, Screen.code("┐"), fg: textFg, bg: textBg)
        s.put(23, 0, Screen.code("└"), fg: textFg, bg: textBg); s.put(23, 79, Screen.code("┘"), fg: textFg, bg: textBg)
        s.text(1, (80 - title.count) / 2, title, fg: textBg, bg: textFg)

        // Text.
        for r in 0..<editRows {
            let row = editTop + r
            s.put(row, 0, Screen.code("│"), fg: textFg, bg: textBg)
            s.put(row, 79, Screen.code("│"), fg: textFg, bg: textBg)
            let li = top + r
            let chars: [Character] = li < lines.count ? Array(lines[li]) : []
            for c in 0..<editCols {
                let ci = left + c
                let ch: Character = ci < chars.count ? chars[ci] : " "
                s.put(row, 1 + c, Screen.code(ch), fg: textFg, bg: textBg)
            }
        }

        // Status bar.
        for c in 0..<80 { s.put(24, c, 32, fg: 0, bg: 3) }
        s.text(24, 1, "<F1=Help> <F5=Run> <F4=Output> <F9=Sound: \(Speaker.shared.output.rawValue)>", fg: 0, bg: 3)
        let pos = String(format: "%05d:%03d", cy + 1, cx + 1)
        s.text(24, 80 - pos.count - 1, pos, fg: 0, bg: 3)
        s.put(24, 80 - pos.count - 3, Screen.code("│"), fg: 0, bg: 3)
        if !insertMode { s.text(24, 80 - pos.count - 6, "OVR", fg: 0, bg: 3) }

        s.curRow = editTop + cy - top
        s.curCol = 1 + cx - left
        s.cursorVisible = true

        switch mode {
        case .dialog(let msg): drawDialog(s, msg)
        case .help(let page): drawHelp(s, page)
        default: break
        }
        s.touch()
    }

    private func box(_ s: Screen, _ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int, fg: UInt8, bg: UInt8) {
        for r in r0...r1 {
            for c in c0...c1 {
                let edgeR = r == r0 || r == r1, edgeC = c == c0 || c == c1
                let ch: Character = edgeR && edgeC ? (r == r0 ? (c == c0 ? "┌" : "┐") : (c == c0 ? "└" : "┘")) : edgeR ? "─" : edgeC ? "│" : " "
                s.put(r, c, Screen.code(ch), fg: fg, bg: bg)
            }
            // Shadow.
            s.put(r, c1 + 1, s.codes[r * 80 + min(79, c1 + 1)], fg: 8, bg: 0)
            s.put(r, c1 + 2, s.codes[r * 80 + min(79, c1 + 2)], fg: 8, bg: 0)
        }
        for c in (c0 + 2)...(c1 + 2) where c < 80 { s.put(r1 + 1, c, s.codes[(r1 + 1) * 80 + c], fg: 8, bg: 0) }
    }

    private func drawDialog(_ s: Screen, _ msg: String) {
        var wrapped: [String] = []
        var cur = ""
        for word in msg.split(separator: " ") {
            if cur.count + word.count + 1 > 56 { wrapped.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + word
        }
        if !cur.isEmpty { wrapped.append(cur) }
        let w = max(24, (wrapped.map(\.count).max() ?? 0) + 6)
        let h = wrapped.count + 4
        let r0 = (25 - h) / 2, c0 = (80 - w) / 2
        box(s, r0, c0, r0 + h - 1, c0 + w - 1, fg: 0, bg: 7)
        for (i, l) in wrapped.enumerated() { s.text(r0 + 1 + i, c0 + (w - l.count) / 2, l, fg: 0, bg: 7) }
        let ok = "< OK >"
        s.text(r0 + h - 2, c0 + (w - ok.count) / 2, ok, fg: 15, bg: 7)
        s.curRow = r0 + h - 2; s.curCol = c0 + (w - ok.count) / 2 + 2
    }

    private func drawHelp(_ s: Screen, _ page: Int) {
        let r0 = 2, c0 = 3, r1 = 22, c1 = 75
        box(s, r0, c0, r1, c1, fg: 0, bg: 7)
        let title = " TrackBASIC Help (\(page + 1)/\(IDE.help.count)) "
        s.text(r0, (80 - title.count) / 2, title, fg: 15, bg: 0)
        for (i, l) in IDE.help[page].enumerated() where i < r1 - r0 - 2 {
            s.text(r0 + 1 + i, c0 + 2, String(l.prefix(c1 - c0 - 3)), fg: 0, bg: 7)
        }
        let foot = page < IDE.help.count - 1 ? "PgDn for more · any other key returns" : "PgUp to go back · any other key returns"
        s.text(r1, (80 - foot.count - 2) / 2, " " + foot + " ", fg: 0, bg: 7)
        s.curRow = r1; s.curCol = 0
    }

    static let help: [[String]] = [
        [
            "TrackBASIC runs QBasic programs, and plays SOUND, PLAY and BEEP",
            "on your MacBook's trackpad: its haptic motor, not the speakers.",
            "Put the Mac on a table and keep your hands off the glass.",
            "",
            "KEYS",
            "  F5          run the program        Ctrl+C   stop it",
            "  F4          look at the output screen",
            "  F9          sound: Trackpad / Speakers / Off",
            "  Ctrl+Y      delete a line          Ins      insert/overwrite",
            "  Cmd+O/S/N   open, save, new        Cmd+V    paste",
            "  File > Examples has programs to try.",
            "",
            "SOUND",
            "  SOUND freq, ticks      freq 37-32767 Hz, 18.2 ticks a second",
            "  PLAY \"T120 O4 L8 CDEFGAB > C\"     BEEP",
            "  Loudest from O4 G to O5 A# (784-1865 Hz). Quiet spots: O4 B",
            "  to O5 C#, and O5 B to O6 C#. Pick a key that avoids them:",
            "  Ode to Joy sounds best in D major, O5.",
        ],
        [
            "STATEMENTS",
            "  PRINT [USING]  INPUT  LINE INPUT  LET  CLS  COLOR  LOCATE",
            "  IF/THEN/ELSE/ELSEIF/END IF    SELECT CASE/CASE/END SELECT",
            "  FOR/NEXT [STEP]  DO/LOOP [WHILE|UNTIL]  WHILE/WEND",
            "  EXIT FOR/DO/SUB/FUNCTION  GOTO  GOSUB/RETURN  ON..GOTO/GOSUB",
            "  DIM [SHARED] [AS type]  REDIM  ERASE  CONST  SWAP",
            "  SUB/FUNCTION/CALL/SHARED  DATA/READ/RESTORE  RANDOMIZE",
            "  SLEEP  END  STOP  SYSTEM  VIEW PRINT  DEFINT/DEFSTR  OPTION BASE",
            "  SOUND  PLAY  BEEP",
            "",
            "GRAPHICS (SCREEN 13 = 320x200x256, SCREEN 12 = 640x480x16)",
            "  SCREEN  PSET  PRESET  LINE [B|BF]  CIRCLE  PAINT  POINT()",
            "",
            "FUNCTIONS",
            "  ABS ATN COS SIN TAN EXP LOG SQR INT FIX CINT SGN RND MOD",
            "  LEN LEFT$ RIGHT$ MID$ INSTR UCASE$ LCASE$ LTRIM$ RTRIM$",
            "  CHR$ ASC STR$ VAL HEX$ OCT$ SPACE$ STRING$ INKEY$ INPUT$",
            "  TIMER DATE$ TIME$ CSRLIN POS LBOUND UBOUND TAB SPC",
        ],
    ]
}
