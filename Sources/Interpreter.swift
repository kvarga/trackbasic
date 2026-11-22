// Runs a compiled Program on its own thread, drawing on a Screen and reading keys from a KeyQueue.

import Foundation

let builtinNames: Set<String> = [
    "ABS", "ASC", "ATN", "CHR$", "CINT", "CLNG", "CSNG", "CDBL", "COS", "EXP", "FIX", "HEX$", "OCT$", "INSTR", "INT",
    "LCASE$", "LEFT$", "LEN", "LOG", "LTRIM$", "MID$", "RIGHT$", "RND", "RTRIM$", "SGN", "SIN", "SPACE$", "SQR", "STR$",
    "STRING$", "TAN", "UCASE$", "VAL", "TIMER", "INKEY$", "DATE$", "TIME$", "CSRLIN", "POS", "POINT", "LBOUND", "UBOUND",
    "INPUT$", "PEEK", "FRE", "TAB", "SPC",
]
private let noArgBuiltins: Set<String> = ["RND", "TIMER", "INKEY$", "DATE$", "TIME$", "CSRLIN", "FRE"]

enum Value {
    case num(Double)
    case str(String)
}

// MARK: - Keyboard

final class KeyQueue {
    private let cond = NSCondition()
    private var keys: [String] = []
    /// Like the PC's keyboard buffer, typing far ahead of the program drops the oldest keys.
    var capacity = 64

    func push(_ k: String) {
        cond.lock(); keys.append(k); if keys.count > capacity { keys.removeFirst() }; cond.signal(); cond.unlock()
    }
    func pop() -> String? {
        cond.lock(); defer { cond.unlock() }
        return keys.isEmpty ? nil : keys.removeFirst()
    }
    func clear() { cond.lock(); keys.removeAll(); cond.unlock() }
    var isEmpty: Bool { cond.lock(); defer { cond.unlock() }; return keys.isEmpty }
    /// Waits for a key to be waiting (without taking it), up to `timeout` seconds; nil waits forever.
    func waitForKey(timeout: Double?, stop: () -> Bool) {
        let end = timeout.map { Date().addingTimeInterval($0) }
        cond.lock(); defer { cond.unlock() }
        while keys.isEmpty && !stop() {
            if let end, Date() >= end { return }
            _ = cond.wait(until: min(end ?? .distantFuture, Date().addingTimeInterval(0.05)))
        }
    }
}

// MARK: - Arrays and frames

final class BArray {
    var lower: [Int], upper: [Int]
    var values: [Value]
    init(lower: [Int], upper: [Int], isString: Bool) throws {
        self.lower = lower; self.upper = upper
        var n = 1
        for (l, u) in zip(lower, upper) {
            guard u >= l else { throw BasicError.subscriptOutOfRange }
            n *= (u - l + 1)
        }
        guard n <= 16_000_000 else { throw BasicError.runtime("Out of memory") }
        values = Array(repeating: isString ? .str("") : .num(0), count: n)
    }
    func index(_ idx: [Int]) throws -> Int {
        guard idx.count == lower.count else { throw BasicError.subscriptOutOfRange }
        var off = 0
        for d in 0..<idx.count {
            guard idx[d] >= lower[d], idx[d] <= upper[d] else { throw BasicError.subscriptOutOfRange }
            off = off * (upper[d] - lower[d] + 1) + (idx[d] - lower[d])
        }
        return off
    }
}

final class Frame {
    let isMain: Bool
    var scalars: [String: Value] = [:]
    var arrays: [String: BArray] = [:]
    var types: [String: String] = [:]
    var shared = Set<String>()
    var forState: [Int: (end: Double, step: Double)] = [:]
    var selectValues: [Int: Value] = [:]
    var gosubStack: [Int] = []
    init(isMain: Bool) { self.isMain = isMain }
}

private enum Signal: Error { case end, stop }

struct RunError: Error { let line: Int; let message: String }

// MARK: - Interpreter

final class Interpreter {
    let prog: Program
    let screen: Screen
    let keys: KeyQueue
    private let main = Frame(isMain: true)
    private var consts: [String: Value] = [:]
    private var globalShared = Set<String>()
    private var dataPtr = 0
    private var rndSeed: UInt32 = 327680
    private var lastRnd = 0.0
    private var curPC = 0
    private var depth = 0
    private let music = MusicState()
    private let soundQueue = DispatchQueue(label: "qbasic.sound")
    private var emptyInkeys = 0

    /// Set from the UI thread to stop the program (Ctrl+Break).
    var stopRequested = false

    init(program: Program, screen: Screen, keys: KeyQueue) {
        prog = program; self.screen = screen; self.keys = keys
    }

    /// Runs to the end. Throws RunError for a runtime error; returns normally on END, STOP or Ctrl+Break.
    func run() throws {
        do {
            try exec(from: 0, frame: main)
        } catch Signal.end {
        } catch Signal.stop {
        } catch let e as BasicError {
            throw RunError(line: prog.lines[min(curPC, prog.lines.count - 1)], message: e.message)
        }
        soundQueue.sync {}   // let background music finish
    }

    private func stopped() -> Bool { stopRequested }

    private func withScreen<T>(_ f: () throws -> T) rethrows -> T {
        screen.lock.lock(); defer { screen.lock.unlock() }
        return try f()
    }

    // MARK: Execution

    private func exec(from start: Int, frame: Frame) throws {
        var pc = start
        while true {
            if stopRequested { throw Signal.stop }
            curPC = pc
            let op = prog.ops[pc]
            pc += 1
            switch op {
            case .nop: break
            case .print(let items): try doPrint(items, frame)
            case .printUsing(let fmt, let items): try doPrintUsing(fmt, items, frame)
            case .assign(let lv, let e): try assign(lv, try eval(e, frame), frame)
            case .input(let prompt, let q, let targets, let whole): try doInput(prompt, q, targets, whole, frame)
            case .goto(let t): pc = t.pc
            case .jumpUnless(let e, let t): if try !truth(e, frame) { pc = t.pc }
            case .jumpIf(let e, let t): if try truth(e, frame) { pc = t.pc }
            case .gosub(let t):
                guard frame.gosubStack.count < 10000 else { throw BasicError.runtime("Out of stack space") }
                frame.gosubStack.append(pc); pc = t.pc
            case .ret(let t):
                guard let back = frame.gosubStack.popLast() else { throw BasicError.returnWithoutGosub }
                pc = t?.pc ?? back
            case .onJump(let e, let ts, let gosub):
                let n = Int(try num(e, frame).rounded())
                if n >= 1 && n <= ts.count {
                    if gosub { frame.gosubStack.append(pc) }
                    pc = ts[n - 1].pc
                }
            case .forStart(let lv, let s, let e, let st, let exit):
                let startV = try num(s, frame), endV = try num(e, frame)
                let stepV = try st.map { try num($0, frame) } ?? 1
                try assign(lv, .num(startV), frame)
                let v = try num(.variable(lv.name), frame)
                frame.forState[pc - 1] = (endV, stepV)
                if stepV >= 0 ? v > endV : v < endV { pc = exit.pc }
            case .next(let fi):
                guard let st = frame.forState[fi], case .forStart(let lv, _, _, _, _) = prog.ops[fi] else { throw BasicError.runtime("NEXT without FOR") }
                let v = try num(.variable(lv.name), frame) + st.step
                try assign(lv, .num(v), frame)
                let now = try num(.variable(lv.name), frame)
                if st.step >= 0 ? now <= st.end : now >= st.end { pc = fi + 1 }
            case .end: throw Signal.end
            case .stop: throw Signal.stop
            case .cls: withScreen { screen.cls() }
            case .color(let a, let b):
                let f = try a.map { try num($0, frame) }, g = try b.map { try num($0, frame) }
                withScreen {
                    if let f { screen.fg = UInt8(clamping: Int(f) & (screen.mode == 13 ? 255 : 15)) }
                    if let g { screen.bg = UInt8(clamping: Int(g) & (screen.mode == 0 ? 7 : 255)) }
                }
            case .locate(let r, let c, let v):
                let rv = try r.map { Int(try num($0, frame)) }, cv = try c.map { Int(try num($0, frame)) }
                let vis = try v.map { try num($0, frame) != 0 }
                try withScreen {
                    if let rv { guard rv >= 1 && rv <= screen.rows else { throw BasicError.illegalFunctionCall("LOCATE row") }; screen.curRow = rv - 1 }
                    if let cv { guard cv >= 1 && cv <= screen.cols else { throw BasicError.illegalFunctionCall("LOCATE column") }; screen.curCol = cv - 1 }
                    if let vis { screen.cursorVisible = vis }
                    screen.touch()
                }
            case .sleep(let e):
                let s = try e.map { try num($0, frame) } ?? 0
                // Like QBasic, SLEEP leaves the key in the buffer for INKEY$ to read.
                keys.waitForKey(timeout: s > 0 ? s : nil, stop: stopped)
            case .beep: playNotes([Note(hz: 880, sound: 0.25, gap: 0)], background: false)
            case .sound(let f, let d):
                let hz = try num(f, frame), ticks = try num(d, frame)
                guard ticks >= 0 && ticks <= 65535 else { throw BasicError.illegalFunctionCall("SOUND duration") }
                guard hz == 0 || (hz >= 37 && hz <= 32767) else { throw BasicError.illegalFunctionCall("SOUND frequency must be 37 to 32767") }
                playNotes([Note(hz: hz, sound: ticks / 18.2, gap: 0)], background: music.background)
            case .play(let e):
                let notes = try music.parse(try str(e, frame))
                playNotes(notes, background: music.background)
            case .randomize(let e):
                var seed = try e.map { try num($0, frame) } ?? Date().timeIntervalSince1970
                if e == nil { seed = Double(Int(seed) % 65536) }
                let bits = seed.bitPattern
                rndSeed = UInt32(truncatingIfNeeded: (bits >> 32) ^ bits) & 0xFFFFFF
            case .dim(let items, let shared, let redim): try doDim(items, shared: shared, redim: redim, frame)
            case .selectStart(let e, let slot): frame.selectValues[slot] = try eval(e, frame)
            case .caseTest(let slot, let tests, let next):
                guard let v = frame.selectValues[slot] else { throw BasicError.runtime("CASE without SELECT") }
                var hit = false
                for t in tests {
                    switch t {
                    case .equals(let e): hit = try compare(v, try eval(e, frame)) == 0
                    case .range(let a, let b): hit = try compare(v, try eval(a, frame)) >= 0 && compare(v, try eval(b, frame)) <= 0
                    case .compare(let op, let e):
                        let c = try compare(v, try eval(e, frame))
                        switch op {
                        case "=": hit = c == 0
                        case "<>": hit = c != 0
                        case "<": hit = c < 0
                        case ">": hit = c > 0
                        case "<=": hit = c <= 0
                        default: hit = c >= 0
                        }
                    }
                    if hit { break }
                }
                if !hit { pc = next.pc }
            case .read(let lvs):
                for lv in lvs {
                    guard dataPtr < prog.data.count else { throw BasicError.outOfData }
                    let raw = prog.data[dataPtr]
                    dataPtr += 1
                    if isStringName(lv.name, frame) { try assign(lv, .str(raw), frame) } else {
                        guard let d = parseNumber(raw) else { throw BasicError.syntax("DATA item \"\(raw)\" isn't a number") }
                        try assign(lv, .num(d), frame)
                    }
                }
            case .restore(let label):
                if let label {
                    guard let i = prog.dataLabels[label] else { throw BasicError.labelNotDefined(label) }
                    dataPtr = i
                } else { dataPtr = 0 }
            case .callSub(let name, let args):
                guard let p = prog.procedures[name], !p.isFunction else { throw BasicError.runtime("Subprogram not defined: \(name)") }
                _ = try call(p, args, frame)
            case .endProc:
                if frame.isMain { throw BasicError.runtime("END SUB outside a SUB") }
                return
            case .screen(let e):
                let m = Int(try num(e, frame))
                try withScreen { try screen.setMode(m) }
            case .pset(let x, let y, let c, let step, let preset):
                try graphics()
                var px = try num(x, frame), py = try num(y, frame)
                let col = try c.map { try num($0, frame) }
                withScreen {
                    if step { px += screen.lastX; py += screen.lastY }
                    let color = col.map { UInt8(clamping: Int($0)) } ?? (preset ? screen.bg : screen.fg)
                    screen.pset(Int(px.rounded()), Int(py.rounded()), color)
                    screen.lastX = px; screen.lastY = py
                    screen.touch()
                }
            case .line(let x1, let y1, let s1, let x2, let y2, let s2, let c, let box, let fill):
                try graphics()
                var ax = try x1.map { try num($0, frame) }, ay = try y1.map { try num($0, frame) }
                var bx = try num(x2, frame), by = try num(y2, frame)
                let col = try c.map { try num($0, frame) }
                withScreen {
                    if ax == nil || ay == nil { ax = screen.lastX; ay = screen.lastY } else if s1 { ax! += screen.lastX; ay! += screen.lastY }
                    if s2 { bx += ax!; by += ay! }
                    let color = col.map { UInt8(clamping: Int($0)) } ?? screen.fg
                    let p = (Int(ax!.rounded()), Int(ay!.rounded()), Int(bx.rounded()), Int(by.rounded()))
                    if box { screen.box(p.0, p.1, p.2, p.3, color, fill: fill) } else { screen.line(p.0, p.1, p.2, p.3, color) }
                    screen.lastX = bx; screen.lastY = by
                    screen.touch()
                }
            case .circle(let x, let y, let r, let c, let a, let step):
                try graphics()
                var cx = try num(x, frame), cy = try num(y, frame)
                let rad = try num(r, frame)
                let col = try c.map { try num($0, frame) }
                let asp = try a.map { try num($0, frame) }
                withScreen {
                    if step { cx += screen.lastX; cy += screen.lastY }
                    let defaultAspect = screen.mode == 13 ? 5.0 / 6.0 : 1.0
                    screen.circle(cx, cy, rad, col.map { UInt8(clamping: Int($0)) } ?? screen.fg, aspect: asp ?? defaultAspect)
                    screen.lastX = cx; screen.lastY = cy
                    screen.touch()
                }
            case .paint(let x, let y, let c, let b, let step):
                try graphics()
                var px = try num(x, frame), py = try num(y, frame)
                let col = try c.map { try num($0, frame) }, bord = try b.map { try num($0, frame) }
                withScreen {
                    if step { px += screen.lastX; py += screen.lastY }
                    let color = col.map { UInt8(clamping: Int($0)) } ?? screen.fg
                    screen.paint(Int(px.rounded()), Int(py.rounded()), color, border: bord.map { UInt8(clamping: Int($0)) } ?? color)
                    screen.touch()
                }
            case .swap(let a, let b):
                let va = try eval(lvExpr(a), frame), vb = try eval(lvExpr(b), frame)
                try assign(a, vb, frame); try assign(b, va, frame)
            case .viewPrint(let a, let b):
                let top = try a.map { Int(try num($0, frame)) }, bottom = try b.map { Int(try num($0, frame)) }
                try withScreen {
                    if let top, let bottom {
                        guard top >= 1, bottom <= screen.rows, top <= bottom else { throw BasicError.illegalFunctionCall("VIEW PRINT") }
                        screen.viewTop = top - 1; screen.viewBottom = bottom - 1
                    } else { screen.viewTop = 0; screen.viewBottom = screen.rows - 1 }
                    screen.curRow = screen.viewTop; screen.curCol = 0
                }
            case .erase(let names):
                for n in names { homeArrayFrame(n, frame).arrays[n] = nil }
            case .shared(let names): frame.shared.formUnion(names)
            case .constant(let name, let e): consts[name] = try eval(e, frame)
            case .midAssign: break
            }
        }
    }

    private func graphics() throws {
        if screen.mode == 0 { throw BasicError.illegalFunctionCall("graphics need SCREEN 12 or SCREEN 13 first") }
    }

    private func lvExpr(_ lv: LValue) -> Expr {
        switch lv {
        case .scalar(let n): return .variable(n)
        case .element(let n, let idx): return .call(n, idx)
        }
    }

    // MARK: Sound

    private func playNotes(_ notes: [Note], background: Bool) {
        let work = { [weak self] in
            for n in notes {
                guard let self, !self.stopRequested else { return }
                Speaker.shared.tone(hz: n.hz, seconds: n.sound, stop: { self.stopRequested })
                if n.gap > 0 { Speaker.shared.tone(hz: 0, seconds: n.gap, stop: { self.stopRequested }) }
            }
        }
        if background { soundQueue.async(execute: work) } else { soundQueue.sync(execute: work) }
    }

    // MARK: Procedures

    private func call(_ p: Procedure, _ args: [Expr], _ caller: Frame) throws -> Value {
        guard args.count == p.params.count else { throw BasicError.runtime("Argument-count mismatch calling \(p.name)") }
        guard depth < 2000 else { throw BasicError.runtime("Out of stack space") }
        let f = Frame(isMain: false)
        var writeBacks: [(String, LValue)] = []
        for (param, arg) in zip(p.params, args) {
            if let t = param.asType { f.types[param.name] = t }
            if param.isArray {
                let name: String
                switch arg {
                case .variable(let n): name = n
                case .call(let n, let a) where a.isEmpty: name = n
                default: throw BasicError.typeMismatch
                }
                f.arrays[param.name] = try lookupArray(name, caller, dims: 1)
                continue
            }
            var v = try eval(arg, caller)
            v = try coerce(v, to: param.name, f)
            f.scalars[param.name] = v
            // Variables are passed by reference: copy the parameter back afterwards.
            switch arg {
            case .variable(let n) where consts[n] == nil && prog.procedures[n] == nil && !noArgBuiltins.contains(n):
                writeBacks.append((param.name, .scalar(n)))
            case .call(let n, let idx) where prog.procedures[n] == nil && !builtinNames.contains(n) && arrayExists(n, caller):
                writeBacks.append((param.name, .element(n, idx)))
            default: break
            }
        }
        if p.isFunction { f.scalars[p.name] = defaultValue(p.name, f) }
        let savedPC = curPC
        depth += 1
        defer { depth -= 1 }
        try exec(from: p.start, frame: f)
        curPC = savedPC
        for (param, lv) in writeBacks { try assign(lv, f.scalars[param] ?? defaultValue(param, f), caller) }
        return f.scalars[p.name] ?? .num(0)
    }

    // MARK: Variables

    private func declaredType(_ name: String, _ frame: Frame) -> String? {
        frame.types[name] ?? (frame.isMain ? nil : (globalShared.contains(name) || frame.shared.contains(name) ? main.types[name] : nil))
    }

    func isStringName(_ name: String, _ frame: Frame) -> Bool {
        if name.hasSuffix("$") { return true }
        if let last = name.last, "%&!#".contains(last) { return false }
        if let t = declaredType(name, frame) { return t == "STRING" }
        if let f = name.first, prog.defStrLetters.contains(f) { return true }
        return false
    }

    private func isIntName(_ name: String, _ frame: Frame) -> Bool {
        if name.hasSuffix("%") || name.hasSuffix("&") { return true }
        if let last = name.last, "$!#".contains(last) { return false }
        if let t = declaredType(name, frame) { return t == "INTEGER" || t == "LONG" }
        if let f = name.first, prog.defIntLetters.contains(f) { return true }
        return false
    }

    private func defaultValue(_ name: String, _ frame: Frame) -> Value { isStringName(name, frame) ? .str("") : .num(0) }

    private func coerce(_ v: Value, to name: String, _ frame: Frame) throws -> Value {
        switch v {
        case .str: if !isStringName(name, frame) { throw BasicError.typeMismatch }
            return v
        case .num(let d):
            if isStringName(name, frame) { throw BasicError.typeMismatch }
            if isIntName(name, frame) {
                let r = d.rounded(.toNearestOrEven)
                if name.hasSuffix("%") || declaredType(name, frame) == "INTEGER" || (!name.hasSuffix("&") && declaredType(name, frame) == nil) {
                    guard r >= -32768 && r <= 32767 else { throw BasicError.overflow }
                } else {
                    guard r >= -2147483648 && r <= 2147483647 else { throw BasicError.overflow }
                }
                return .num(r)
            }
            return v
        }
    }

    private func scalarFrame(_ name: String, _ frame: Frame) -> Frame {
        if frame.isMain || frame.scalars[name] != nil { return frame }
        if globalShared.contains(name) || frame.shared.contains(name) { return main }
        return frame
    }

    private func homeArrayFrame(_ name: String, _ frame: Frame) -> Frame {
        if frame.isMain || frame.arrays[name] != nil { return frame }
        if globalShared.contains(name) || frame.shared.contains(name) || main.arrays[name] != nil && globalShared.contains(name) { return main }
        return frame
    }

    private func arrayExists(_ name: String, _ frame: Frame) -> Bool { homeArrayFrame(name, frame).arrays[name] != nil }

    private func lookupArray(_ name: String, _ frame: Frame, dims: Int) throws -> BArray {
        let home = homeArrayFrame(name, frame)
        if let a = home.arrays[name] { return a }
        // Using an array without DIM gives it 0 (or OPTION BASE) to 10 in each dimension.
        let a = try BArray(lower: Array(repeating: prog.optionBase, count: dims), upper: Array(repeating: 10, count: dims),
                           isString: isStringName(name, frame))
        home.arrays[name] = a
        return a
    }

    private func assign(_ lv: LValue, _ v: Value, _ frame: Frame) throws {
        switch lv {
        case .scalar(let name):
            if consts[name] != nil { throw BasicError.runtime("Duplicate definition: \(name) is a CONST") }
            let home = scalarFrame(name, frame)
            home.scalars[name] = try coerce(v, to: name, home)
        case .element(let name, let idx):
            let a = try lookupArray(name, frame, dims: idx.count)
            let i = try a.index(idx.map { Int(try num($0, frame).rounded(.toNearestOrEven)) })
            a.values[i] = try coerce(v, to: name, homeArrayFrame(name, frame))
        }
    }

    private func doDim(_ items: [DimItem], shared: Bool, redim: Bool, _ frame: Frame) throws {
        for item in items {
            if let t = item.asType { frame.types[item.name] = t }
            if shared { globalShared.insert(item.name) }
            if item.bounds.isEmpty {
                if frame.scalars[item.name] == nil { frame.scalars[item.name] = defaultValue(item.name, frame) }
                continue
            }
            if !redim, frame.arrays[item.name] != nil { throw BasicError.runtime("Array already dimensioned: \(item.name)") }
            var lo: [Int] = [], hi: [Int] = []
            for (l, u) in item.bounds {
                lo.append(try l.map { Int(try num($0, frame)) } ?? prog.optionBase)
                hi.append(Int(try num(u, frame)))
            }
            homeArrayFrame(item.name, frame).arrays[item.name] = try BArray(lower: lo, upper: hi, isString: isStringName(item.name, frame))
        }
    }

    // MARK: Expressions

    private func truth(_ e: Expr, _ frame: Frame) throws -> Bool { try num(e, frame) != 0 }

    private func num(_ e: Expr, _ frame: Frame) throws -> Double {
        guard case .num(let d) = try eval(e, frame) else { throw BasicError.typeMismatch }
        return d
    }

    private func str(_ e: Expr, _ frame: Frame) throws -> String {
        guard case .str(let s) = try eval(e, frame) else { throw BasicError.typeMismatch }
        return s
    }

    private func compare(_ a: Value, _ b: Value) throws -> Int {
        switch (a, b) {
        case (.num(let x), .num(let y)): return x < y ? -1 : x > y ? 1 : 0
        case (.str(let x), .str(let y)):
            let xs = Array(x.unicodeScalars), ys = Array(y.unicodeScalars)
            for (p, q) in zip(xs, ys) where p != q { return p.value < q.value ? -1 : 1 }
            return xs.count < ys.count ? -1 : xs.count > ys.count ? 1 : 0
        default: throw BasicError.typeMismatch
        }
    }

    private func toInt(_ d: Double) throws -> Int {
        let r = d.rounded(.toNearestOrEven)
        guard r >= -2147483648 && r <= 2147483647 else { throw BasicError.overflow }
        return Int(r)
    }

    func eval(_ e: Expr, _ frame: Frame) throws -> Value {
        switch e {
        case .num(let d): return .num(d)
        case .str(let s): return .str(s)
        case .variable(let name):
            if let c = consts[name] { return c }
            let home = scalarFrame(name, frame)
            if let v = home.scalars[name] { return v }
            if let p = prog.procedures[name], p.isFunction { return try call(p, [], frame) }
            if noArgBuiltins.contains(name) { return try builtin(name, [], frame) }
            return defaultValue(name, frame)
        case .call(let name, let args):
            if let p = prog.procedures[name], p.isFunction { return try call(p, args, frame) }
            if builtinNames.contains(name) && !arrayExists(name, frame) { return try builtin(name, args, frame) }
            let a = try lookupArray(name, frame, dims: args.count)
            return a.values[try a.index(args.map { try toInt(try num($0, frame)) })]
        case .unary(let op, let x):
            let v = try num(x, frame)
            if op == "-" { return .num(-v) }
            return .num(Double(~(try toInt(v))))
        case .binary(let op, let l, let r):
            let a = try eval(l, frame), b = try eval(r, frame)
            switch op {
            case "=", "<>", "<", ">", "<=", ">=":
                let c = try compare(a, b)
                let t: Bool
                switch op {
                case "=": t = c == 0
                case "<>": t = c != 0
                case "<": t = c < 0
                case ">": t = c > 0
                case "<=": t = c <= 0
                default: t = c >= 0
                }
                return .num(t ? -1 : 0)
            case "+":
                if case .str(let x) = a, case .str(let y) = b { return .str(x + y) }
                guard case .num(let x) = a, case .num(let y) = b else { throw BasicError.typeMismatch }
                return .num(x + y)
            default:
                guard case .num(let x) = a, case .num(let y) = b else { throw BasicError.typeMismatch }
                switch op {
                case "-": return .num(x - y)
                case "*": return .num(x * y)
                case "/":
                    guard y != 0 else { throw BasicError.divisionByZero }
                    return .num(x / y)
                case "\\":
                    let d = try toInt(y)
                    guard d != 0 else { throw BasicError.divisionByZero }
                    return .num(Double(try toInt(x) / d))
                case "MOD":
                    let d = try toInt(y)
                    guard d != 0 else { throw BasicError.divisionByZero }
                    return .num(Double(try toInt(x) % d))
                case "^":
                    let p = pow(x, y)
                    if p.isNaN { throw BasicError.illegalFunctionCall("") }
                    if p.isInfinite { throw x == 0 ? BasicError.divisionByZero : BasicError.overflow }
                    return .num(p)
                case "AND": return .num(Double(try toInt(x) & toInt(y)))
                case "OR": return .num(Double(try toInt(x) | toInt(y)))
                case "XOR": return .num(Double(try toInt(x) ^ toInt(y)))
                case "EQV": return .num(Double(~(try toInt(x) ^ toInt(y))))
                case "IMP": return .num(Double(~(try toInt(x)) | (try toInt(y))))
                default: throw BasicError.syntax("unknown operator \(op)")
                }
            }
        }
    }

    // MARK: Built-in functions

    private func nextRnd() -> Double {
        rndSeed = (rndSeed &* 16598013 &+ 12820163) & 0xFFFFFF
        lastRnd = Double(rndSeed) / 16777216
        return lastRnd
    }

    private func builtin(_ name: String, _ args: [Expr], _ frame: Frame) throws -> Value {
        func n(_ i: Int) throws -> Double {
            guard i < args.count else { throw BasicError.runtime("Argument-count mismatch in \(name)") }
            return try num(args[i], frame)
        }
        func s(_ i: Int) throws -> String {
            guard i < args.count else { throw BasicError.runtime("Argument-count mismatch in \(name)") }
            return try str(args[i], frame)
        }
        func i(_ k: Int) throws -> Int { try toInt(try n(k)) }
        func scalars(_ str: String) -> [UnicodeScalar] { Array(str.unicodeScalars) }
        func string(_ sc: some Sequence<UnicodeScalar>) -> String { var r = ""; r.unicodeScalars.append(contentsOf: sc); return r }

        switch name {
        case "ABS": return .num(abs(try n(0)))
        case "ASC":
            guard let c = try s(0).unicodeScalars.first else { throw BasicError.illegalFunctionCall("ASC of an empty string") }
            return .num(Double(c.value < 256 ? c.value : Screen.code(Character(c))))
        case "ATN": return .num(atan(try n(0)))
        case "CHR$":
            let c = try i(0)
            guard c >= 0 && c <= 255 else { throw BasicError.illegalFunctionCall("CHR$(\(c))") }
            return .str(String(UnicodeScalar(UInt8(c))))
        case "CINT", "CLNG": return .num(Double(try i(0)))
        case "CSNG", "CDBL": return .num(try n(0))
        case "COS": return .num(cos(try n(0)))
        case "EXP": return .num(exp(try n(0)))
        case "FIX": return .num((try n(0)).rounded(.towardZero))
        case "INT": return .num((try n(0)).rounded(.down))
        case "HEX$": return .str(String(UInt32(truncatingIfNeeded: try i(0)), radix: 16).uppercased())
        case "OCT$": return .str(String(UInt32(truncatingIfNeeded: try i(0)), radix: 8))
        case "INSTR":
            var start = 1, hayI = 0
            if args.count == 3 { start = try i(0); hayI = 1 }
            let hay = scalars(try s(hayI)), needle = scalars(try s(hayI + 1))
            guard start >= 1 else { throw BasicError.illegalFunctionCall("INSTR start") }
            if needle.isEmpty { return .num(start <= hay.count ? Double(start) : 0) }
            if hay.count >= needle.count, start - 1 <= hay.count - needle.count {
                for k in (start - 1)...(hay.count - needle.count) where Array(hay[k..<(k + needle.count)]) == needle { return .num(Double(k + 1)) }
            }
            return .num(0)
        case "LCASE$": return .str(try s(0).lowercased())
        case "UCASE$": return .str(try s(0).uppercased())
        case "LEFT$":
            let k = try i(1)
            guard k >= 0 else { throw BasicError.illegalFunctionCall("LEFT$") }
            return .str(string(scalars(try s(0)).prefix(k)))
        case "RIGHT$":
            let k = try i(1)
            guard k >= 0 else { throw BasicError.illegalFunctionCall("RIGHT$") }
            return .str(string(scalars(try s(0)).suffix(k)))
        case "MID$":
            let sc = scalars(try s(0)), start = try i(1)
            guard start >= 1 else { throw BasicError.illegalFunctionCall("MID$ start") }
            let len = args.count > 2 ? try i(2) : sc.count
            guard len >= 0 else { throw BasicError.illegalFunctionCall("MID$ length") }
            if start > sc.count { return .str("") }
            return .str(string(sc[(start - 1)..<min(sc.count, start - 1 + len)]))
        case "LEN":
            if case .variable(let v) = args.first, !isStringName(v, frame) { return .num(isIntName(v, frame) ? 2 : 4) }
            return .num(Double(scalars(try s(0)).count))
        case "LOG":
            let x = try n(0)
            guard x > 0 else { throw BasicError.illegalFunctionCall("LOG of \(x)") }
            return .num(log(x))
        case "LTRIM$": return .str(String(try s(0).drop { $0 == " " }))
        case "RTRIM$":
            var t = try s(0)
            while t.hasSuffix(" ") { t.removeLast() }
            return .str(t)
        case "RND":
            if args.isEmpty { return .num(nextRnd()) }
            let x = try n(0)
            if x == 0 { return .num(lastRnd) }
            if x < 0 { rndSeed = UInt32(truncatingIfNeeded: x.bitPattern >> 40) & 0xFFFFFF }
            return .num(nextRnd())
        case "SGN": let x = try n(0); return .num(x > 0 ? 1 : x < 0 ? -1 : 0)
        case "SIN": return .num(sin(try n(0)))
        case "SPACE$":
            let k = try i(0)
            guard k >= 0 else { throw BasicError.illegalFunctionCall("SPACE$") }
            return .str(String(repeating: " ", count: k))
        case "SQR":
            let x = try n(0)
            guard x >= 0 else { throw BasicError.illegalFunctionCall("SQR of a negative number") }
            return .num(sqrt(x))
        case "STR$":
            let x = try n(0)
            var t = formatNumber(x)
            t.removeLast()
            return .str(t)
        case "STRING$":
            let k = try i(0)
            guard k >= 0 else { throw BasicError.illegalFunctionCall("STRING$") }
            let v = try eval(args[1], frame)
            var ch: UnicodeScalar
            switch v {
            case .num(let c): ch = UnicodeScalar(UInt8(clamping: Int(c)))
            case .str(let t):
                guard let f = t.unicodeScalars.first else { throw BasicError.illegalFunctionCall("STRING$") }
                ch = f
            }
            return .str(string(Array(repeating: ch, count: k)))
        case "TAN": return .num(tan(try n(0)))
        case "VAL": return .num(parseNumber(try s(0), lenient: true) ?? 0)
        case "TIMER":
            let comps = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
            let secs = Double(comps.hour! * 3600 + comps.minute! * 60 + comps.second!) + Double(comps.nanosecond!) / 1e9
            return .num((secs * 100).rounded(.down) / 100)
        case "INKEY$":
            if let k = keys.pop() { emptyInkeys = 0; return .str(k) }
            emptyInkeys += 1
            if emptyInkeys > 200 { usleep(500) }   // a program spinning on INKEY$ shouldn't pin a core
            return .str("")
        case "DATE$":
            let f = DateFormatter(); f.dateFormat = "MM-dd-yyyy"
            return .str(f.string(from: Date()))
        case "TIME$":
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            return .str(f.string(from: Date()))
        case "CSRLIN": return .num(Double(withScreen { screen.curRow + 1 }))
        case "POS": return .num(Double(withScreen { screen.curCol + 1 }))
        case "POINT":
            let x = try i(0), y = try i(1)
            return .num(Double(withScreen { screen.point(x, y) }))
        case "SCREEN":
            let r = try i(0) - 1, c = try i(1) - 1
            return .num(Double(withScreen { r >= 0 && r < screen.rows && c >= 0 && c < screen.cols ? Int(screen.codes[r * screen.cols + c]) : 0 }))
        case "LBOUND", "UBOUND":
            guard case .variable(let an) = args.first else { throw BasicError.typeMismatch }
            let a = try lookupArray(an, frame, dims: 1)
            let d = args.count > 1 ? try i(1) - 1 : 0
            guard d >= 0 && d < a.lower.count else { throw BasicError.subscriptOutOfRange }
            return .num(Double(name == "LBOUND" ? a.lower[d] : a.upper[d]))
        case "INPUT$":
            let k = try i(0)
            var out = ""
            while out.unicodeScalars.count < k {
                keys.waitForKey(timeout: nil, stop: stopped)
                if stopRequested { throw Signal.stop }
                if let key = keys.pop() { out += key }
            }
            return .str(out)
        case "PEEK": return .num(0)
        case "FRE": return .num(60000)
        case "TAB", "SPC": throw BasicError.runtime("\(name) only works in PRINT")
        default: throw BasicError.runtime("Unknown function \(name)")
        }
    }

    // MARK: Numbers

    /// How PRINT shows a number: a leading space (or minus), up to 7 significant digits, a trailing space.
    func formatNumber(_ d: Double) -> String {
        var s: String
        if d == d.rounded() && abs(d) < 1e15 {
            s = String(Int64(abs(d)))
        } else {
            s = String(format: "%.7G", abs(d))
            if s.contains("E") {
                // 1.5E+20 → 1.5E+20, 1E-05 → 1E-05: QBasic uses at least two exponent digits.
                s = s.replacingOccurrences(of: "E+0", with: "E+").replacingOccurrences(of: "E-0", with: "E-")
                if let r = s.range(of: "E") {
                    let mant = s[..<r.lowerBound], exp = s[r.upperBound...]
                    let sign = exp.first!, digits = exp.dropFirst()
                    s = mant + "E" + String(sign) + (digits.count < 2 ? "0" : "") + digits
                }
            }
            if s.hasPrefix("0.") { s.removeFirst() }
        }
        return (d < 0 ? "-" : " ") + s + " "
    }

    func parseNumber(_ raw: String, lenient: Bool = false) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return lenient ? 0 : 0 }
        if t.uppercased().hasPrefix("&H") { return Double(Int(t.dropFirst(2), radix: 16) ?? 0) }
        if let d = Double(t.replacingOccurrences(of: "D", with: "E").replacingOccurrences(of: "d", with: "e")) { return d }
        guard lenient else { return nil }
        // VAL reads as much of a number as it can: VAL("12abc") = 12.
        var best: Double?
        var prefix = ""
        for c in t where c != " " {
            prefix.append(c)
            if let d = Double(prefix) { best = d } else if !(c == "e" || c == "E" || c == "-" || c == "+" || c == ".") { break }
        }
        return best ?? 0
    }

    // MARK: PRINT

    private func doPrint(_ items: [PrintItem], _ frame: Frame) throws {
        var newlineAtEnd = true
        for item in items {
            if let e = item.expr {
                if case .call("TAB", let a) = e, a.count == 1 {
                    let col = max(1, try toInt(try num(a[0], frame))) - 1
                    withScreen {
                        let target = col % screen.cols
                        if screen.curCol > target { screen.newline() }
                        screen.write(String(repeating: " ", count: target - screen.curCol))
                    }
                } else if case .call("SPC", let a) = e, a.count == 1 {
                    let n = max(0, try toInt(try num(a[0], frame)))
                    withScreen { screen.write(String(repeating: " ", count: n % max(1, screen.cols))) }
                } else {
                    let v = try eval(e, frame)
                    let s: String
                    switch v {
                    case .num(let d): s = formatNumber(d)
                    case .str(let t): s = t
                    }
                    withScreen {
                        if case .num = v, screen.curCol > 0, screen.curCol + s.count > screen.cols { screen.newline() }
                        screen.write(s)
                    }
                }
            }
            switch item.sep {
            case .none: newlineAtEnd = true
            case .semicolon: newlineAtEnd = false
            case .comma:
                newlineAtEnd = false
                withScreen {
                    let next = (screen.curCol / 14 + 1) * 14
                    if next >= screen.cols { screen.newline() } else { screen.write(String(repeating: " ", count: next - screen.curCol)) }
                }
            }
        }
        if newlineAtEnd { withScreen { screen.newline(); screen.touch() } }
    }

    private func doPrintUsing(_ fmtE: Expr, _ items: [PrintItem], _ frame: Frame) throws {
        let fmt = Array(try str(fmtE, frame))
        let values = try items.compactMap { $0.expr }.map { try eval($0, frame) }
        guard !values.isEmpty else { return }
        var out = ""
        var vi = 0
        var i = 0
        var usedField = false
        while vi < values.count {
            if i >= fmt.count {
                guard usedField else { throw BasicError.illegalFunctionCall("PRINT USING has no fields") }
                i = 0
            }
            let c = fmt[i]
            switch c {
            case "_":
                if i + 1 < fmt.count { out.append(fmt[i + 1]) }
                i += 2
            case "!", "&", "\\":
                guard case .str(let s) = values[vi] else { throw BasicError.typeMismatch }
                usedField = true
                if c == "!" { out += String(s.prefix(1)); i += 1 } else if c == "&" { out += s; i += 1 } else {
                    var j = i + 1
                    while j < fmt.count && fmt[j] == " " { j += 1 }
                    guard j < fmt.count, fmt[j] == "\\" else { out.append(c); i += 1; continue }
                    let w = j - i + 1
                    out += s.padding(toLength: w, withPad: " ", startingAt: 0)
                    i = j + 1
                }
                vi += 1
            case "#", "+", "$", "*", ".":
                // A numeric field: optional +, $$ or **, digits with optional commas, decimals, ^^^^ or trailing sign.
                var j = i
                var plus = false, dollar = false, stars = false, comma = false
                var intDigits = 0, decDigits = -1
                if fmt[j] == "+" { plus = true; j += 1 }
                if j + 1 < fmt.count, fmt[j] == "$", fmt[j + 1] == "$" { dollar = true; intDigits += 1; j += 2 }
                else if j + 1 < fmt.count, fmt[j] == "*", fmt[j + 1] == "*" {
                    stars = true; intDigits += 2; j += 2
                    if j < fmt.count, fmt[j] == "$" { dollar = true; j += 1 }
                }
                while j < fmt.count, fmt[j] == "#" || fmt[j] == "," { if fmt[j] == "," { comma = true } else { intDigits += 1 }; j += 1 }
                if j < fmt.count, fmt[j] == "." {
                    decDigits = 0; j += 1
                    while j < fmt.count, fmt[j] == "#" { decDigits += 1; j += 1 }
                }
                if intDigits == 0 && decDigits <= 0 { out.append(c); i += 1; continue }
                var trailingSign = false
                if j < fmt.count, fmt[j] == "-" || fmt[j] == "+" { trailingSign = true; if fmt[j] == "+" { plus = true }; j += 1 }
                guard case .num(let d) = values[vi] else { throw BasicError.typeMismatch }
                usedField = true
                var body = String(format: "%.\(max(0, decDigits))f", abs(d))
                if decDigits == 0 { body += "." }
                if comma, let dot = body.firstIndex(of: ".") ?? Optional(body.endIndex) {
                    var intPart = String(body[..<dot])
                    let rest = String(body[dot...])
                    var grouped = ""
                    while intPart.count > 3 { grouped = "," + intPart.suffix(3) + grouped; intPart.removeLast(3) }
                    body = intPart + grouped + rest
                }
                if body.hasPrefix("0.") && intDigits <= 1 && decDigits > 0 && intDigits == 0 { body.removeFirst() }
                var sign = d < 0 ? "-" : (plus ? "+" : "")
                if trailingSign { body += d < 0 ? "-" : (plus ? "+" : " "); sign = "" }
                if dollar { body = "$" + body }
                body = sign + body
                let width = (plus && !trailingSign ? 1 : 0) + intDigits + (comma ? (intDigits - 1) / 3 : 0) + (decDigits >= 0 ? decDigits + 1 : 0) + (trailingSign ? 1 : 0)
                if body.count > width { out += "%" + body } else {
                    out += String(repeating: stars ? "*" : " ", count: width - body.count) + body
                }
                i = j
                vi += 1
            default:
                out.append(c); i += 1
            }
        }
        // Literal text after the last field.
        while i < fmt.count, !"#!&\\+$*".contains(fmt[i]) { out.append(fmt[i]); i += 1 }
        let endsLine = items.last?.sep == PrintSep.none
        withScreen {
            screen.write(out)
            if endsLine { screen.newline() }
            screen.touch()
        }
    }

    // MARK: INPUT

    private func readLine() throws -> String {
        var text: [UnicodeScalar] = []
        withScreen { screen.cursorVisible = true; screen.touch() }
        while true {
            keys.waitForKey(timeout: nil, stop: stopped)
            if stopRequested { throw Signal.stop }
            guard let k = keys.pop() else { continue }
            if k == "\r" { withScreen { screen.newline(); screen.touch() }; return string(text) }
            if k == "\u{8}" {
                if !text.isEmpty {
                    text.removeLast()
                    withScreen {
                        if screen.curCol > 0 { screen.curCol -= 1 } else if screen.curRow > 0 { screen.curRow -= 1; screen.curCol = screen.cols - 1 }
                        screen.put(screen.curRow, screen.curCol, 32, fg: screen.fg, bg: screen.bg)
                        screen.touch()
                    }
                }
                continue
            }
            if k == "\u{1B}" {
                withScreen {
                    for _ in text {
                        if screen.curCol > 0 { screen.curCol -= 1 } else if screen.curRow > 0 { screen.curRow -= 1; screen.curCol = screen.cols - 1 }
                        screen.put(screen.curRow, screen.curCol, 32, fg: screen.fg, bg: screen.bg)
                    }
                    screen.touch()
                }
                text.removeAll()
                continue
            }
            guard let sc = k.unicodeScalars.first, k.unicodeScalars.count == 1, sc.value >= 32 else { continue }
            text.append(sc)
            withScreen { screen.write(k) }
        }
    }

    private func string(_ sc: [UnicodeScalar]) -> String { var r = ""; r.unicodeScalars.append(contentsOf: sc); return r }

    private func doInput(_ prompt: String?, _ question: Bool, _ targets: [LValue], _ whole: Bool, _ frame: Frame) throws {
        while true {
            withScreen { screen.write((prompt ?? "") + (question ? "? " : "")) }
            let line = try readLine()
            if whole { try assign(targets[0], .str(line), frame); return }
            // Split on commas outside quotes.
            var parts: [String] = []
            var cur = "", inQ = false, quoted = false
            for ch in line {
                if ch == "\"" { inQ.toggle(); quoted = true; continue }
                if ch == "," && !inQ { parts.append(quoted ? cur : cur.trimmingCharacters(in: .whitespaces)); cur = ""; quoted = false; continue }
                cur.append(ch)
            }
            parts.append(quoted ? cur : cur.trimmingCharacters(in: .whitespaces))
            var ok = parts.count == targets.count
            var values: [Value] = []
            if ok {
                for (t, p) in zip(targets, parts) {
                    if isStringName(t.name, frame) { values.append(.str(p)) } else if let d = parseNumber(p) { values.append(.num(d)) } else { ok = false; break }
                }
            }
            if ok {
                for (t, v) in zip(targets, values) { try assign(t, v, frame) }
                return
            }
            withScreen { screen.write("Redo from start\n") }
        }
    }
}
