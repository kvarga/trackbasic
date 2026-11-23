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

    private enum Mode { case editing, running, finished, viewingOutput, dialog(String), help(Int), menu(bar: Int, open: Bool, item: Int) }
    private var mode = Mode.editing

    private let keys = KeyQueue()
    private var interpreter: Interpreter?

    // Layout (80×25): menu bar, frame top, 21 text rows, frame bottom, status bar.
    private let editTop = 2, editRows = 21, editCols = 78

    // Colours: QBasic's editor is grey on blue, with a grey menu bar and a cyan status bar.
    private let textFg: UInt8 = 7, textBg: UInt8 = 1

    init() {
        view = ScreenView(screen: editorScreen)
        view.onKey = { [weak self] e in self?.altAlone = false; self?.key(e) }
        view.onFlags = { [weak self] e in self?.flags(e) }
        view.onMouse = { [weak self] r, c, p in self?.mouse(r, c, p) }
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
        case .menu(let bar, let open, let item):
            menuKey(e, bar: bar, open: open, item: item, lower: lower, fkey: fkey)
        case .editing:
            if fkey == NSF10FunctionKey { openMenu(0, open: false); return }
            // Option+letter opens that menu, as Alt+letter does in QBasic.
            if e.modifierFlags.contains(.option), !ctrl, let b = barIndex(hotkey: lower) { openMenu(b, open: true); return }
            editKey(e, ctrl: ctrl, lower: lower, fkey: fkey)
        }
    }

    // MARK: Menus

    /// The menus shown in the blue window's bar: the app's own menus (File, Edit, Run, Sound, Help), set by
    /// the app delegate, so the two always offer the same commands.
    var menuSource: (() -> [NSMenuItem])?

    private struct Entry {
        let item: NSMenuItem?      // nil = separator
        let label: String
        let hint: String
        let hotkey: Character?
    }

    private var bars: [NSMenuItem] { menuSource?() ?? [] }

    private func entries(_ bar: Int) -> [Entry] {
        let all = bars
        guard bar < all.count, let menu = all[bar].submenu else { return [] }
        var flat: [NSMenuItem?] = []
        for i in menu.items {
            if i.isSeparatorItem { flat.append(nil) }
            else if let sub = i.submenu { flat.append(nil); flat += sub.items.map { $0.isSeparatorItem ? nil : $0 } }
            else { flat.append(i) }
        }
        // No separators at either end or twice in a row.
        var cleaned: [NSMenuItem?] = []
        for i in flat where !(i == nil && (cleaned.isEmpty || cleaned.last! == nil)) { cleaned.append(i) }
        if cleaned.last.map({ $0 == nil }) == true { cleaned.removeLast() }

        var used = Set<Character>()
        return cleaned.map { i in
            guard let i else { return Entry(item: nil, label: "", hint: "", hotkey: nil) }
            let label = i.title
            let key = label.lowercased().first { $0.isLetter && !used.contains($0) }
            if let key { used.insert(key) }
            return Entry(item: i, label: label, hint: IDE.hint(i), hotkey: key)
        }
    }

    private static func hint(_ i: NSMenuItem) -> String {
        if let t = i.toolTip { return t }
        guard !i.keyEquivalent.isEmpty else { return "" }
        let m = i.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + i.keyEquivalent.uppercased()
    }

    private func enabled(_ i: NSMenuItem) -> Bool {
        guard i.action != nil else { return false }
        if let v = i.target as? NSMenuItemValidation { return v.validateMenuItem(i) }
        return true
    }

    /// Column of each bar title. Help sits at the right, as in QBasic.
    private func barColumns() -> [Int] {
        var col = 2
        return bars.map { b in
            if b.submenu?.title == "Help" { return 80 - 2 - b.submenu!.title.count }
            defer { col += b.submenu!.title.count + 2 }
            return col
        }
    }

    private func barIndex(hotkey: String) -> Int? {
        guard let k = hotkey.first else { return nil }
        return bars.firstIndex { $0.submenu?.title.lowercased().first == k }
    }

    func openMenu(_ bar: Int, open: Bool) {
        guard !bars.isEmpty else { return }
        tidy(cy)
        let b = (bar + bars.count) % bars.count
        mode = .menu(bar: b, open: open, item: open ? step(b, from: -1, by: 1) : 0)
        render()
    }

    private func closeMenu() { mode = .editing; render() }

    /// The next item that isn't a separator, going `by` ±1 and wrapping.
    private func step(_ bar: Int, from: Int, by: Int) -> Int {
        let e = entries(bar)
        guard !e.isEmpty else { return 0 }
        var i = from
        for _ in 0..<e.count {
            i = (i + by + e.count) % e.count
            if e[i].item != nil { return i }
        }
        return 0
    }

    private func choose(_ bar: Int, _ index: Int) {
        let e = entries(bar)
        guard index >= 0, index < e.count, let item = e[index].item, enabled(item) else { return }
        closeMenu()
        NSApp.sendAction(item.action!, to: item.target, from: item)
    }

    private func menuKey(_ e: NSEvent, bar: Int, open: Bool, item: Int, lower: String, fkey: Int) {
        switch fkey {
        case NSLeftArrowFunctionKey: openMenu(bar - 1, open: open); return
        case NSRightArrowFunctionKey: openMenu(bar + 1, open: open); return
        case NSDownArrowFunctionKey:
            if open { mode = .menu(bar: bar, open: true, item: step(bar, from: item, by: 1)); render() } else { openMenu(bar, open: true) }
            return
        case NSUpArrowFunctionKey:
            if open { mode = .menu(bar: bar, open: true, item: step(bar, from: item, by: -1)); render() } else { openMenu(bar, open: true) }
            return
        case NSF10FunctionKey: closeMenu(); return
        default: break
        }
        switch e.characters?.unicodeScalars.first?.value ?? 0 {
        case 0x1B: closeMenu()
        case 0x0D, 0x03, 0x20: if open { choose(bar, item) } else { openMenu(bar, open: true) }
        default:
            guard let k = lower.first else { return }
            if open, let i = entries(bar).firstIndex(where: { $0.hotkey == k }) { choose(bar, i) }
            else if let b = barIndex(hotkey: lower) { openMenu(b, open: true) }
        }
    }

    /// Alt pressed and released on its own enters or leaves the menu bar, as in QBasic.
    private var altAlone = false
    private func flags(_ e: NSEvent) {
        let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if m == .option { altAlone = true; return }
        guard m.isEmpty, altAlone else { altAlone = false; return }
        altAlone = false
        switch mode {
        case .editing: openMenu(0, open: false)
        case .menu: closeMenu()
        default: break
        }
    }

    /// The drop-down's box for a bar: rows r0…r1, columns c0…c1.
    private func dropBox(_ bar: Int) -> (r0: Int, c0: Int, r1: Int, c1: Int, width: Int) {
        let e = entries(bar)
        let labelW = e.map(\.label.count).max() ?? 0, hintW = e.map(\.hint.count).max() ?? 0
        let w = labelW + (hintW > 0 ? hintW + 3 : 0) + 4
        var c0 = barColumns()[bar] - 1
        c0 = min(c0, 77 - w)
        return (1, c0, 1 + e.count + 1, c0 + w - 1, w)
    }

    private func drawMenu(_ s: Screen, bar: Int, open: Bool, item: Int) {
        let cols = barColumns(), title = bars[bar].submenu!.title
        s.text(0, cols[bar] - 1, " " + title + " ", fg: 7, bg: 0)
        guard open else { return }
        let e = entries(bar)
        let (r0, c0, r1, c1, w) = dropBox(bar)
        box(s, r0, c0, r1, c1, fg: 0, bg: 7)
        for (i, en) in e.enumerated() {
            let row = r0 + 1 + i
            guard let it = en.item else {
                s.put(row, c0, Screen.code("├"), fg: 0, bg: 7)
                for c in (c0 + 1)..<c1 { s.put(row, c, Screen.code("─"), fg: 0, bg: 7) }
                s.put(row, c1, Screen.code("┤"), fg: 0, bg: 7)
                continue
            }
            let on = enabled(it), sel = i == item
            let fg: UInt8 = sel ? 7 : (on ? 0 : 8), bg: UInt8 = sel ? 0 : 7
            let mark = it.state == .on ? "•" : " "
            var line = mark + en.label
            line += String(repeating: " ", count: max(1, w - 2 - line.count - en.hint.count - 1)) + en.hint + " "
            s.text(row, c0 + 1, line, fg: fg, bg: bg)
            if on, let k = en.hotkey, let at = Array(en.label.lowercased()).firstIndex(of: k) {
                let col = c0 + 2 + at
                s.put(row, col, s.codes[row * 80 + col], fg: 15, bg: bg)
            }
        }
    }

    // MARK: Mouse

    private var menuDragged = false

    private func mouse(_ row: Int, _ col: Int, _ phase: ScreenView.MousePhase) {
        switch mode {
        case .editing:
            guard phase == .down else { return }
            if row == 0 { if let b = barHit(col) { openMenu(b, open: true); menuDragged = false } }
            else if row >= editTop && row < editTop + editRows && col >= 1 && col <= editCols {
                moveTo(top + row - editTop, left + col - 1)
            } else if row == 24 { statusClick(col) }
        case .menu(let bar, let open, _):
            let hit = barHit(row == 0 ? col : -1)
            let box = dropBox(bar)
            let inItem = open && row > box.r0 && row < box.r1 && col > box.c0 && col < box.c1
            switch phase {
            case .down:
                menuDragged = false
                if let hit { if hit == bar && open { closeMenu() } else { openMenu(hit, open: true) } }
                else if inItem { highlight(bar, row - box.r0 - 1) }
                else { closeMenu() }
            case .drag:
                menuDragged = true
                if let hit, hit != bar { openMenu(hit, open: true) }
                else if inItem { highlight(bar, row - box.r0 - 1) }
            case .up:
                if inItem { choose(bar, row - box.r0 - 1) }
                else if menuDragged && hit == nil { closeMenu() }
            }
        case .dialog, .help:
            if phase == .up { mode = .editing; render() }
        case .finished, .viewingOutput:
            if phase == .up { backToEditor() }
        case .running:
            break
        }
    }

    private func highlight(_ bar: Int, _ index: Int) {
        guard entries(bar).indices.contains(index), entries(bar)[index].item != nil else { return }
        mode = .menu(bar: bar, open: true, item: index); render()
    }

    private func barHit(_ col: Int) -> Int? {
        let all = bars
        for (i, c) in barColumns().enumerated() where col >= c - 1 && col <= c + all[i].submenu!.title.count { return i }
        return nil
    }

    private static let statusText = "<F1=Help> <F5=Run> <F4=Output> <F9=Sound: "
    private func statusClick(_ col: Int) {
        let t = Array(IDE.statusText)
        guard col >= 1, col - 1 < t.count + 12 else { return }
        let i = min(col - 1, t.count - 1)
        // Find the <...> field the click is in.
        var start = i
        while start > 0 && t[start] != "<" { start -= 1 }
        switch String(t[start..<min(start + 3, t.count)]) {
        case "<F1": mode = .help(0); render()
        case "<F5": run()
        case "<F4": toggleOutput()
        case "<F9": cycleSound()
        default: break
        }
    }

    func showHelp() { if case .editing = mode { mode = .help(0); render() } }

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
        for (b, col) in zip(bars, barColumns()) {
            let t = b.submenu!.title
            s.text(0, col, t, fg: 0, bg: 7)
            s.put(0, col, Screen.code(t.first!), fg: 15, bg: 7)
        }

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
        s.text(24, 1, IDE.statusText + "\(Speaker.shared.output.rawValue)>", fg: 0, bg: 3)
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
        case .menu(let bar, let open, let item):
            drawMenu(s, bar: bar, open: open, item: item)
            s.cursorVisible = false
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
