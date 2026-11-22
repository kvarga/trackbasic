// Compiles QBasic source into a flat list of instructions. Block structures (IF, FOR, DO, WHILE,
// SELECT CASE, SUB, FUNCTION) become jumps whose targets are filled in as the blocks close.

import Foundation

indirect enum Expr {
    case num(Double)
    case str(String)
    case variable(String)
    case call(String, [Expr])
    case unary(String, Expr)
    case binary(String, Expr, Expr)
}

enum LValue {
    case scalar(String)
    case element(String, [Expr])
    var name: String {
        switch self { case .scalar(let n), .element(let n, _): return n }
    }
}

/// A jump destination; created before its position is known and filled in later.
final class Target {
    var pc = -1
    var label: String?
    init(label: String? = nil) { self.label = label }
}

enum PrintSep { case none, semicolon, comma }
struct PrintItem { var expr: Expr?; var sep: PrintSep }

enum CaseTest {
    case equals(Expr)
    case range(Expr, Expr)
    case compare(String, Expr)
}

struct DimItem {
    var name: String
    var bounds: [(Expr?, Expr)]   // (lower, upper); empty for a scalar declaration
    var asType: String?
}

struct Param { var name: String; var isArray: Bool; var asType: String? }

final class Procedure {
    let name: String
    let params: [Param]
    let isFunction: Bool
    var start = 0
    init(name: String, params: [Param], isFunction: Bool) { self.name = name; self.params = params; self.isFunction = isFunction }
}

enum Op {
    case nop
    case print(items: [PrintItem])
    case printUsing(format: Expr, items: [PrintItem])
    case assign(LValue, Expr)
    case input(prompt: String?, question: Bool, targets: [LValue], wholeLine: Bool)
    case goto(Target)
    case jumpUnless(Expr, Target)
    case jumpIf(Expr, Target)
    case gosub(Target)
    case ret(Target?)
    case onJump(Expr, [Target], gosub: Bool)
    case forStart(variable: LValue, start: Expr, end: Expr, step: Expr?, exit: Target)
    case next(forIndex: Int)
    case end
    case cls
    case color(Expr?, Expr?)
    case locate(Expr?, Expr?, Expr?)
    case sleep(Expr?)
    case beep
    case sound(Expr, Expr)
    case play(Expr)
    case randomize(Expr?)
    case dim([DimItem], shared: Bool, redim: Bool)
    case selectStart(Expr, slot: Int)
    case caseTest(slot: Int, tests: [CaseTest], next: Target)
    case read([LValue])
    case restore(String?)
    case callSub(String, [Expr])
    case endProc
    case screen(Expr)
    case pset(x: Expr, y: Expr, color: Expr?, step: Bool, preset: Bool)
    case line(x1: Expr?, y1: Expr?, step1: Bool, x2: Expr, y2: Expr, step2: Bool, color: Expr?, box: Bool, fill: Bool)
    case circle(x: Expr, y: Expr, r: Expr, color: Expr?, aspect: Expr?, step: Bool)
    case paint(x: Expr, y: Expr, color: Expr?, border: Expr?, step: Bool)
    case swap(LValue, LValue)
    case viewPrint(Expr?, Expr?)
    case erase([String])
    case shared([String])
    case constant(String, Expr)
    case midAssign(LValue, Expr, Expr?, Expr)
    case stop
}

final class Program {
    var ops: [Op] = []
    var lines: [Int] = []                     // source line (0-based) of each op
    var labels: [String: Int] = [:]
    var procedures: [String: Procedure] = [:]
    var data: [String] = []
    var dataLabels: [String: Int] = [:]
    var defIntLetters = Set<Character>()
    var defStrLetters = Set<Character>()
    var optionBase = 0
}

struct ParseError: Error { let line: Int; let message: String }

final class Parser {
    private var toks: [Token] = []
    private var pos = 0
    private var lineNo = 0
    private var rawLine = ""
    private let prog = Program()

    private enum Block {
        case ifBlock(next: Target?, end: Target)
        case forBlock(index: Int, varName: String, exit: Target)
        case whileBlock(start: Int, end: Target)
        case doBlock(start: Int, end: Target)
        case selectBlock(slot: Int, next: Target?, end: Target)
        case procBlock(Procedure, skip: Target)
    }
    private var blocks: [Block] = []
    private var targets: [Target] = []

    static func compile(_ source: [String]) throws -> Program {
        let p = Parser()
        try p.run(source)
        return p.prog
    }

    private func run(_ source: [String]) throws {
        for (n, line) in source.enumerated() {
            lineNo = n
            rawLine = line
            do {
                toks = try tokenize(line)
                pos = 0
                try parseLine()
            } catch let e as BasicError {
                throw ParseError(line: n, message: e.message)
            }
        }
        lineNo = max(0, source.count - 1)
        emit(.end)
        if let b = blocks.last {
            let what: String
            switch b {
            case .ifBlock: what = "IF without END IF"
            case .forBlock: what = "FOR without NEXT"
            case .whileBlock: what = "WHILE without WEND"
            case .doBlock: what = "DO without LOOP"
            case .selectBlock: what = "SELECT CASE without END SELECT"
            case .procBlock(let p, _): what = (p.isFunction ? "FUNCTION" : "SUB") + " without END " + (p.isFunction ? "FUNCTION" : "SUB")
            }
            throw ParseError(line: lineNo, message: what)
        }
        for t in targets where t.label != nil {
            guard let pc = prog.labels[t.label!] else { throw ParseError(line: lineFor(t), message: "Label not defined: \(t.label!)") }
            t.pc = pc
        }
    }

    private var targetLines: [ObjectIdentifier: Int] = [:]
    private func lineFor(_ t: Target) -> Int { targetLines[ObjectIdentifier(t)] ?? 0 }

    // MARK: Helpers

    private var tok: Token { toks[pos] }
    private func peek(_ n: Int = 1) -> Token { toks[min(pos + n, toks.count - 1)] }
    private func advance() -> Token { let t = toks[pos]; if pos < toks.count - 1 { pos += 1 }; return t }
    private func isKw(_ k: String) -> Bool { tok.kind == .keyword && tok.text == k }
    private func isOp(_ o: String) -> Bool { tok.kind == .op && tok.text == o }
    private func accept(kw k: String) -> Bool { if isKw(k) { pos += 1; return true }; return false }
    private func accept(op o: String) -> Bool { if isOp(o) { pos += 1; return true }; return false }
    private func expect(kw k: String) throws { guard accept(kw: k) else { throw BasicError.syntax("expected \(k)") } }
    private func expect(op o: String) throws { guard accept(op: o) else { throw BasicError.syntax("expected '\(o)'") } }
    private var atEnd: Bool { tok.kind == .eol || isOp(":") || isKw("ELSE") }

    private var pendingLabels: [String] = []

    @discardableResult
    private func emit(_ op: Op) -> Int {
        pendingLabels.removeAll()
        prog.ops.append(op)
        prog.lines.append(lineNo)
        return prog.ops.count - 1
    }
    private func newTarget(label: String? = nil) -> Target {
        let t = Target(label: label)
        targets.append(t)
        targetLines[ObjectIdentifier(t)] = lineNo
        return t
    }
    private func here(_ t: Target) { t.pc = prog.ops.count }
    private func labelTarget() throws -> Target {
        let t = advance()
        switch t.kind {
        case .number: return newTarget(label: t.text)
        case .ident: return newTarget(label: t.text)
        default: throw BasicError.syntax("expected a line number or label")
        }
    }

    // MARK: Lines

    private func parseLine() throws {
        // A line number, or "label:" at the start of the line.
        if tok.kind == .number {
            let l = advance().text
            prog.labels[l] = prog.ops.count
            pendingLabels.append(l)
        } else if tok.kind == .ident && peek().kind == .op && peek().text == ":" && !tok.text.hasSuffix("$") {
            prog.labels[tok.text] = prog.ops.count
            pendingLabels.append(tok.text)
            pos += 2
        }
        // DATA takes the raw rest of the line. RESTORE label finds the DATA that follows the label.
        if isKw("DATA") {
            for l in pendingLabels where prog.dataLabels[l] == nil { prog.dataLabels[l] = prog.data.count }
            pendingLabels.removeAll()
            let rest = String(rawLine.dropFirst(tok.column + 4))
            prog.data += splitData(rest)
            return
        }
        try parseStatements(singleLineIf: false)
        if tok.kind != .eol { throw BasicError.syntax("unexpected \(tok.text.isEmpty ? "end" : tok.text)") }
    }

    private func splitData(_ s: String) -> [String] {
        var items: [String] = []
        var cur = "", inQuote = false, quoted = false
        for c in s {
            if c == "\"" { inQuote.toggle(); quoted = true; continue }
            if c == "," && !inQuote { items.append(quoted ? cur : cur.trimmingCharacters(in: .whitespaces)); cur = ""; quoted = false; continue }
            cur.append(c)
        }
        items.append(quoted ? cur : cur.trimmingCharacters(in: .whitespaces))
        return items
    }

    /// Statements separated by ':' until the end of the line (or ELSE, inside a single-line IF).
    private func parseStatements(singleLineIf: Bool) throws {
        while true {
            if tok.kind == .eol { return }
            if singleLineIf && isKw("ELSE") { return }
            if accept(op: ":") { continue }
            try parseStatement()
            if singleLineIf && isKw("ELSE") { return }
            if tok.kind == .eol { return }
            // A block IF ... THEN at the end of a line can't be followed by more.
            if !accept(op: ":") {
                if isKw("ELSE") && !singleLineIf { continue }
                throw BasicError.syntax("expected end of statement, found \(tok.text)")
            }
        }
    }

    // MARK: Statements

    private func parseStatement() throws {
        let t = tok
        if t.kind == .ident || (t.kind == .keyword && t.text == "LET") {
            if accept(kw: "LET") {}
            // A bare SUB name is a call: "MySub 1, 2".
            if tok.kind == .ident && !(peek().kind == .op && (peek().text == "=" || peek().text == "(")) {
                let name = advance().text
                var args: [Expr] = []
                if !atEnd { args = try exprList() }
                emit(.callSub(name, args))
                return
            }
            if tok.kind == .ident, peek().kind == .op, peek().text == "(" {
                // Could be an array assignment or "MySub (x)": look for '=' after the closing paren.
                let save = pos
                let lv = try lvalue()
                if accept(op: "=") {
                    emit(.assign(lv, try expr()))
                    return
                }
                pos = save
                let name = advance().text
                emit(.callSub(name, try exprList()))
                return
            }
            let lv = try lvalue()
            try expect(op: "=")
            emit(.assign(lv, try expr()))
            return
        }
        guard t.kind == .keyword else { throw BasicError.syntax("unexpected \(t.text)") }
        pos += 1
        switch t.text {
        case "REM": pos = toks.count - 1
        case "PRINT":
            if accept(kw: "USING") {
                let fmt = try expr()
                try expect(op: ";")
                emit(.printUsing(format: fmt, items: try printItems()))
            } else {
                emit(.print(items: try printItems()))
            }
        case "INPUT": try parseInput(wholeLine: false)
        case "LINE":
            if accept(kw: "INPUT") { try parseInput(wholeLine: true) } else { try parseLineGraphics() }
        case "IF": try parseIf()
        case "ELSEIF":
            guard case .ifBlock(let next, let end)? = blocks.last else { throw BasicError.syntax("ELSEIF without IF") }
            emit(.goto(end))
            if let next { here(next) }
            let cond = try expr()
            try expect(kw: "THEN")
            let n = newTarget()
            emit(.jumpUnless(cond, n))
            blocks[blocks.count - 1] = .ifBlock(next: n, end: end)
        case "ELSE":
            guard case .ifBlock(let next, let end)? = blocks.last else { throw BasicError.syntax("ELSE without IF") }
            emit(.goto(end))
            if let next { here(next) }
            blocks[blocks.count - 1] = .ifBlock(next: nil, end: end)
        case "END": try parseEnd()
        case "FOR":
            guard tok.kind == .ident else { throw BasicError.syntax("expected a variable after FOR") }
            let name = advance().text
            try expect(op: "=")
            let start = try expr()
            try expect(kw: "TO")
            let end = try expr()
            var step: Expr?
            if accept(kw: "STEP") { step = try expr() }
            let exit = newTarget()
            let i = emit(.forStart(variable: .scalar(name), start: start, end: end, step: step, exit: exit))
            blocks.append(.forBlock(index: i, varName: name, exit: exit))
        case "NEXT":
            repeat {
                guard case .forBlock(let i, let v, let exit)? = blocks.last else { throw BasicError.syntax("NEXT without FOR") }
                if tok.kind == .ident {
                    let name = advance().text
                    if name != v { throw BasicError.syntax("NEXT \(name) doesn't match FOR \(v)") }
                }
                emit(.next(forIndex: i))
                here(exit)
                blocks.removeLast()
            } while accept(op: ",")
        case "WHILE":
            let end = newTarget()
            let start = prog.ops.count
            emit(.jumpUnless(try expr(), end))
            blocks.append(.whileBlock(start: start, end: end))
        case "WEND":
            guard case .whileBlock(let start, let end)? = blocks.last else { throw BasicError.syntax("WEND without WHILE") }
            let s = newTarget(); s.pc = start
            emit(.goto(s))
            here(end)
            blocks.removeLast()
        case "DO":
            let end = newTarget()
            let start = prog.ops.count
            if accept(kw: "WHILE") { emit(.jumpUnless(try expr(), end)) } else if accept(kw: "UNTIL") { emit(.jumpIf(try expr(), end)) }
            blocks.append(.doBlock(start: start, end: end))
        case "LOOP":
            guard case .doBlock(let start, let end)? = blocks.last else { throw BasicError.syntax("LOOP without DO") }
            let s = newTarget(); s.pc = start
            if accept(kw: "WHILE") { emit(.jumpIf(try expr(), s)) } else if accept(kw: "UNTIL") { emit(.jumpUnless(try expr(), s)) } else { emit(.goto(s)) }
            here(end)
            blocks.removeLast()
        case "EXIT":
            if accept(kw: "FOR") {
                guard let b = blocks.reversed().first(where: { if case .forBlock = $0 { return true }; return false }),
                      case .forBlock(_, _, let exit) = b else { throw BasicError.syntax("EXIT FOR outside FOR") }
                emit(.goto(exit))
            } else if accept(kw: "DO") {
                guard let b = blocks.reversed().first(where: { if case .doBlock = $0 { return true }; return false }),
                      case .doBlock(_, let end) = b else { throw BasicError.syntax("EXIT DO outside DO") }
                emit(.goto(end))
            } else if accept(kw: "SUB") || accept(kw: "FUNCTION") {
                emit(.endProc)
            } else { throw BasicError.syntax("EXIT what?") }
        case "GOTO": emit(.goto(try labelTarget()))
        case "GOSUB": emit(.gosub(try labelTarget()))
        case "RETURN": emit(.ret(atEnd ? nil : try labelTarget()))
        case "ON":
            let e = try expr()
            let isGosub: Bool
            if accept(kw: "GOTO") { isGosub = false } else if accept(kw: "GOSUB") { isGosub = true } else { throw BasicError.syntax("expected GOTO or GOSUB") }
            var ts = [try labelTarget()]
            while accept(op: ",") { ts.append(try labelTarget()) }
            emit(.onJump(e, ts, gosub: isGosub))
        case "DIM", "REDIM": try parseDim(redim: t.text == "REDIM")
        case "CLS": if !atEnd { _ = try expr() }; emit(.cls)
        case "COLOR":
            let a = isOp(",") ? nil : try expr()
            var b: Expr?
            if accept(op: ",") { b = try expr() }
            if accept(op: ",") { _ = try expr() }
            emit(.color(a, b))
        case "LOCATE":
            var args: [Expr?] = [nil, nil, nil]
            var i = 0
            while !atEnd && i < 5 {
                if isOp(",") { pos += 1; i += 1; continue }
                let e = try expr()
                if i < 3 { args[i] = e }
                if !accept(op: ",") { break }
                i += 1
            }
            emit(.locate(args[0], args[1], args[2]))
        case "SLEEP": emit(.sleep(atEnd ? nil : try expr()))
        case "BEEP": emit(.beep)
        case "SOUND":
            let f = try expr(); try expect(op: ","); emit(.sound(f, try expr()))
        case "PLAY": emit(.play(try expr()))
        case "RANDOMIZE": emit(.randomize(atEnd ? nil : try expr()))
        case "SELECT":
            try expect(kw: "CASE")
            let e = try expr()
            let slot = prog.ops.count
            emit(.selectStart(e, slot: slot))
            blocks.append(.selectBlock(slot: slot, next: nil, end: newTarget()))
        case "CASE":
            guard case .selectBlock(let slot, let next, let end)? = blocks.last else { throw BasicError.syntax("CASE without SELECT") }
            if let next { emit(.goto(end)); here(next) } else if prog.ops.count - 1 != slot { emit(.goto(end)) }
            if accept(kw: "ELSE") {
                blocks[blocks.count - 1] = .selectBlock(slot: slot, next: nil, end: end)
            } else {
                var tests: [CaseTest] = []
                repeat {
                    if accept(kw: "IS") {
                        let op = advance()
                        guard op.kind == .op, ["=", "<>", "<", ">", "<=", ">="].contains(op.text) else { throw BasicError.syntax("expected a comparison after IS") }
                        tests.append(.compare(op.text, try expr()))
                    } else {
                        let a = try expr()
                        if accept(kw: "TO") { tests.append(.range(a, try expr())) } else { tests.append(.equals(a)) }
                    }
                } while accept(op: ",")
                let n = newTarget()
                emit(.caseTest(slot: slot, tests: tests, next: n))
                blocks[blocks.count - 1] = .selectBlock(slot: slot, next: n, end: end)
            }
        case "READ":
            var lvs = [try lvalue()]
            while accept(op: ",") { lvs.append(try lvalue()) }
            emit(.read(lvs))
        case "RESTORE": emit(.restore(atEnd ? nil : advance().text))
        case "DATA": pos = toks.count - 1
        case "SUB", "FUNCTION": try parseProcedure(isFunction: t.text == "FUNCTION")
        case "CALL":
            guard tok.kind == .ident else { throw BasicError.syntax("expected a SUB name after CALL") }
            let name = advance().text
            var args: [Expr] = []
            if accept(op: "(") { if !isOp(")") { args = try exprList() }; try expect(op: ")") }
            emit(.callSub(name, args))
        case "DECLARE": pos = toks.count - 1
        case "CONST":
            repeat {
                guard tok.kind == .ident else { throw BasicError.syntax("expected a name after CONST") }
                let name = advance().text
                try expect(op: "=")
                emit(.constant(name, try expr()))
            } while accept(op: ",")
        case "SHARED", "STATIC":
            var names: [String] = []
            repeat {
                guard tok.kind == .ident else { throw BasicError.syntax("expected a name") }
                names.append(advance().text)
                if accept(op: "(") { try expect(op: ")") }
                if accept(kw: "AS") { pos += 1 }
            } while accept(op: ",")
            if t.text == "SHARED" { emit(.shared(names)) }
        case "SCREEN": emit(.screen(try expr())); while accept(op: ",") { _ = try expr() }
        case "PSET", "PRESET":
            let step = accept(kw: "STEP")
            try expect(op: "(")
            let x = try expr(); try expect(op: ","); let y = try expr(); try expect(op: ")")
            var c: Expr?
            if accept(op: ",") { c = try expr() }
            emit(.pset(x: x, y: y, color: c, step: step, preset: t.text == "PRESET"))
        case "CIRCLE":
            let step = accept(kw: "STEP")
            try expect(op: "(")
            let x = try expr(); try expect(op: ","); let y = try expr(); try expect(op: ")")
            try expect(op: ",")
            let r = try expr()
            var c: Expr?, aspect: Expr?
            var extra = 0
            while accept(op: ",") {
                extra += 1
                if isOp(",") || atEnd { continue }
                let e = try expr()
                if extra == 1 { c = e } else if extra == 4 { aspect = e }
            }
            emit(.circle(x: x, y: y, r: r, color: c, aspect: aspect, step: step))
        case "PAINT":
            let step = accept(kw: "STEP")
            try expect(op: "(")
            let x = try expr(); try expect(op: ","); let y = try expr(); try expect(op: ")")
            var c: Expr?, b: Expr?
            if accept(op: ",") { if !isOp(",") { c = try expr() } }
            if accept(op: ",") { b = try expr() }
            emit(.paint(x: x, y: y, color: c, border: b, step: step))
        case "SWAP":
            let a = try lvalue(); try expect(op: ","); emit(.swap(a, try lvalue()))
        case "STOP": emit(.stop)
        case "SYSTEM": emit(.end)
        case "VIEW":
            try expect(kw: "PRINT")
            if atEnd { emit(.viewPrint(nil, nil)) } else {
                let a = try expr(); try expect(kw: "TO"); emit(.viewPrint(a, try expr()))
            }
        case "WIDTH", "KEY": pos = toks.count - 1
        case "ERASE":
            var names = [advance().text]
            while accept(op: ",") { names.append(advance().text) }
            emit(.erase(names))
        case "OPTION":
            try expect(kw: "BASE")
            prog.optionBase = Int(advance().number)
        case "DEFINT", "DEFLNG", "DEFSNG", "DEFDBL", "DEFSTR":
            repeat {
                let a = advance().text
                var letters = [a]
                if accept(op: "-") {
                    let b = advance().text
                    if let s = a.unicodeScalars.first?.value, let e = b.unicodeScalars.first?.value, s <= e {
                        letters = (s...e).map { String(UnicodeScalar($0)!) }
                    }
                }
                for l in letters {
                    guard let c = l.first else { continue }
                    switch t.text {
                    case "DEFINT", "DEFLNG": prog.defIntLetters.insert(c); prog.defStrLetters.remove(c)
                    case "DEFSTR": prog.defStrLetters.insert(c); prog.defIntLetters.remove(c)
                    default: prog.defIntLetters.remove(c); prog.defStrLetters.remove(c)
                    }
                }
            } while accept(op: ",")
        default:
            throw BasicError.syntax("\(t.text) isn't supported here")
        }
    }

    private func parseEnd() throws {
        if atEnd { emit(.end); return }
        let what = advance().text
        switch what {
        case "IF":
            guard case .ifBlock(let next, let end)? = blocks.last else { throw BasicError.syntax("END IF without IF") }
            if let next { here(next) }
            here(end)
            blocks.removeLast()
        case "SELECT":
            guard case .selectBlock(_, let next, let end)? = blocks.last else { throw BasicError.syntax("END SELECT without SELECT") }
            if let next { here(next) }
            here(end)
            blocks.removeLast()
        case "SUB", "FUNCTION":
            guard case .procBlock(_, let skip)? = blocks.last else { throw BasicError.syntax("END \(what) without \(what)") }
            emit(.endProc)
            here(skip)
            blocks.removeLast()
        default: throw BasicError.syntax("END \(what)?")
        }
    }

    private func parseIf() throws {
        let cond = try expr()
        if accept(kw: "GOTO") {
            emit(.jumpIf(cond, try labelTarget()))
            return
        }
        try expect(kw: "THEN")
        if tok.kind == .eol {
            let next = newTarget()
            emit(.jumpUnless(cond, next))
            blocks.append(.ifBlock(next: next, end: newTarget()))
            return
        }
        // Single-line IF.
        let elseT = newTarget(), endT = newTarget()
        emit(.jumpUnless(cond, elseT))
        if tok.kind == .number { emit(.goto(try labelTarget())) } else { try parseStatements(singleLineIf: true) }
        if accept(kw: "ELSE") {
            emit(.goto(endT))
            here(elseT)
            if tok.kind == .number { emit(.goto(try labelTarget())) } else { try parseStatements(singleLineIf: true) }
        } else {
            here(elseT)
        }
        here(endT)
    }

    private func parseInput(wholeLine: Bool) throws {
        _ = accept(op: ";")
        var prompt: String?
        var question = true
        if tok.kind == .string && (peek().text == ";" || peek().text == ",") {
            prompt = advance().text
            question = advance().text == ";"
        }
        var lvs = [try lvalue()]
        while accept(op: ",") { lvs.append(try lvalue()) }
        emit(.input(prompt: prompt, question: question && !wholeLine, targets: lvs, wholeLine: wholeLine))
    }

    private func parseLineGraphics() throws {
        var x1: Expr?, y1: Expr?
        var step1 = false
        if accept(kw: "STEP") { step1 = true }
        if accept(op: "(") {
            x1 = try expr(); try expect(op: ","); y1 = try expr(); try expect(op: ")")
        }
        try expect(op: "-")
        let step2 = accept(kw: "STEP")
        try expect(op: "(")
        let x2 = try expr(); try expect(op: ","); let y2 = try expr(); try expect(op: ")")
        var color: Expr?
        var box = false, fill = false
        if accept(op: ",") {
            if !isOp(",") && !atEnd { color = try expr() }
            if accept(op: ",") {
                if tok.kind == .ident && (tok.text == "B" || tok.text == "BF") {
                    box = true; fill = advance().text == "BF"
                }
                if accept(op: ",") { _ = try expr() }
            }
        }
        emit(.line(x1: x1, y1: y1, step1: step1, x2: x2, y2: y2, step2: step2, color: color, box: box, fill: fill))
    }

    private func parseDim(redim: Bool) throws {
        let shared = accept(kw: "SHARED")
        var items: [DimItem] = []
        repeat {
            guard tok.kind == .ident else { throw BasicError.syntax("expected a name after DIM") }
            var item = DimItem(name: advance().text, bounds: [], asType: nil)
            if accept(op: "(") {
                repeat {
                    let a = try expr()
                    if accept(kw: "TO") { item.bounds.append((a, try expr())) } else { item.bounds.append((nil, a)) }
                } while accept(op: ",")
                try expect(op: ")")
            }
            if accept(kw: "AS") {
                item.asType = advance().text
                if accept(op: "*") { _ = advance() }   // STRING * n: fixed length, treated as variable length
            }
            items.append(item)
        } while accept(op: ",")
        emit(.dim(items, shared: shared, redim: redim))
    }

    private func parseProcedure(isFunction: Bool) throws {
        guard tok.kind == .ident else { throw BasicError.syntax("expected a name") }
        let name = advance().text
        var params: [Param] = []
        if accept(op: "(") {
            if !isOp(")") {
                repeat {
                    guard tok.kind == .ident else { throw BasicError.syntax("expected a parameter name") }
                    var p = Param(name: advance().text, isArray: false, asType: nil)
                    if accept(op: "(") { try expect(op: ")"); p.isArray = true }
                    if accept(kw: "AS") { p.asType = advance().text }
                    params.append(p)
                } while accept(op: ",")
            }
            try expect(op: ")")
        }
        _ = accept(kw: "STATIC")
        if !blocks.isEmpty { throw BasicError.syntax("SUB or FUNCTION inside another block") }
        let proc = Procedure(name: name, params: params, isFunction: isFunction)
        let skip = newTarget()
        emit(.goto(skip))
        proc.start = prog.ops.count
        prog.procedures[name] = proc
        blocks.append(.procBlock(proc, skip: skip))
    }

    private func printItems() throws -> [PrintItem] {
        var items: [PrintItem] = []
        while !atEnd {
            if accept(op: ";") { items.append(PrintItem(expr: nil, sep: .semicolon)); continue }
            if accept(op: ",") { items.append(PrintItem(expr: nil, sep: .comma)); continue }
            let e = try expr()
            var sep = PrintSep.none
            if accept(op: ";") { sep = .semicolon } else if accept(op: ",") { sep = .comma }
            items.append(PrintItem(expr: e, sep: sep))
        }
        return items
    }

    private func lvalue() throws -> LValue {
        guard tok.kind == .ident else { throw BasicError.syntax("expected a variable, found \(tok.text.isEmpty ? "end of line" : tok.text)") }
        let name = advance().text
        if accept(op: "(") {
            let idx = try exprList()
            try expect(op: ")")
            return .element(name, idx)
        }
        return .scalar(name)
    }

    // MARK: Expressions (QBasic precedence, lowest first)

    private func exprList() throws -> [Expr] {
        var list = [try expr()]
        while accept(op: ",") { list.append(try expr()) }
        return list
    }

    func expr() throws -> Expr { try binaryLevel(0) }

    private static let levels: [[String]] = [
        ["IMP"], ["EQV"], ["XOR"], ["OR"], ["AND"], [], ["=", "<>", "<", ">", "<=", ">="], ["+", "-"], ["MOD"], ["\\"], ["*", "/"],
    ]

    private func binaryLevel(_ level: Int) throws -> Expr {
        if level == 5 {   // NOT sits between AND and the comparisons
            if accept(kw: "NOT") { return .unary("NOT", try binaryLevel(5)) }
            return try binaryLevel(6)
        }
        if level >= Parser.levels.count { return try unary() }
        var lhs = try binaryLevel(level + 1)
        while (tok.kind == .op || tok.kind == .keyword), Parser.levels[level].contains(tok.text) {
            let op = advance().text
            lhs = .binary(op, lhs, try binaryLevel(level + 1))
        }
        return lhs
    }

    private func unary() throws -> Expr {
        if accept(op: "-") { return .unary("-", try unary()) }
        if accept(op: "+") { return try unary() }
        return try power()
    }

    private func power() throws -> Expr {
        var base = try primary()
        while accept(op: "^") {
            // Exponent may itself be negated: 2 ^ -1.
            let rhs: Expr = accept(op: "-") ? .unary("-", try primary()) : try primary()
            base = .binary("^", base, rhs)
        }
        return base
    }

    private func primary() throws -> Expr {
        let t = advance()
        switch t.kind {
        case .number: return .num(t.number)
        case .string: return .str(t.text)
        case .ident:
            if accept(op: "(") {
                var args: [Expr] = []
                if !isOp(")") { args = try exprList() }
                try expect(op: ")")
                return .call(t.text, args)
            }
            return .variable(t.text)
        case .op where t.text == "(":
            let e = try expr()
            try expect(op: ")")
            return e
        case .keyword where t.text == "NOT":
            return .unary("NOT", try binaryLevel(6))
        case .keyword where t.text == "SCREEN" || t.text == "STRING" || t.text == "PLAY":
            // SCREEN(row, col) and similar keyword-named functions.
            try expect(op: "(")
            let args = try exprList()
            try expect(op: ")")
            return .call(t.text, args)
        default:
            throw BasicError.syntax("expected an expression, found \(t.text.isEmpty ? "end of line" : t.text)")
        }
    }
}
